require "yaml"
require "tmpdir"
require "open3"

workflow = YAML.safe_load(
  File.read(File.expand_path("../workflows/deploy.yml", __dir__)),
  aliases: true
)
step = workflow.fetch("jobs").fetch("deploy").fetch("steps").find do |entry|
  entry["id"] == "update-branch"
end

steps = workflow.fetch("jobs").fetch("deploy").fetch("steps")
validation = steps.find { |entry| entry["id"] == "validate-webhook" }.fetch("run")
notifications = steps.select { |entry| entry["run"].to_s.include?('curl --fail') }
raise "Expected start and failure notifications" unless notifications.size == 2
raise "Webhook must be a required secret" unless workflow.fetch("on") {
  workflow.fetch(true)
}.fetch("workflow_call").fetch("secrets").fetch("CHAT_WEBHOOK_URL").fetch("required")

Dir.mktmpdir("deploy-notification-selftest-") do |dir|
  log = File.join(dir, "calls")
  mock_path = File.join(dir, "mock.sh")
  File.write(mock_path, <<~'BASH')
    curl() {
      printf '%s\n' "$@" >> "$CALL_LOG"
      return "$CURL_STATUS"
    }
    export -f curl
  BASH
  File.write(File.join(dir, "batou"), "#!/bin/sh\nprintf 'batou\\n' >> \"$CALL_LOG\"\n")
  File.chmod(0o755, File.join(dir, "batou"))
  env = {
    "CHAT_WEBHOOK_URL" => "https://chat.example.invalid/webhook/test",
    "GITHUB_SERVER_URL" => "https://github.com",
    "GITHUB_REPOSITORY" => "example/deployment",
    "GITHUB_RUN_ID" => "123",
    "BASH_ENV" => mock_path,
    "CALL_LOG" => log,
    "CURL_STATUS" => "0"
  }
  ["", "http://chat.example.invalid/webhook/test", "https://"].each do |url|
    _, status = Open3.capture2e(env.merge("CHAT_WEBHOOK_URL" => url),
                              "bash", "-euo", "pipefail", "-c", validation)
    raise "Invalid webhook accepted" if status.success?
  end
  _, status = Open3.capture2e(env, "bash", "-euo", "pipefail", "-c", validation)
  raise "Valid webhook rejected" unless status.success?

  notifications.each do |notification|
    script = notification.fetch("run").gsub("${{ inputs.target }}", "staging")
    ["0", "22"].each do |curl_status|
      File.write(log, "")
      _, status = Open3.capture2e(env.merge("CURL_STATUS" => curl_status),
                                "bash", "-euo", "pipefail", "-c", script, chdir: dir)
      raise "Notification exit status ignored" unless status.success? == (curl_status == "0")
      calls = File.readlines(log, chomp: true)
      raise "Configured webhook not used" unless calls.include?(env["CHAT_WEBHOOK_URL"])
      raise "HTTP failures not checked" unless calls.include?("--fail")
      if script.include?("./batou")
        raise "Unexpected deployment after notification failure" unless calls.include?("batou") == (curl_status == "0")
      end
    end
  end
end
puts "Webhook configuration, both notification destinations and HTTP failures: OK"
script = step.fetch("run")
revision = "b" * 40

# Simulate Git so these checks never change a checkout, refs, or a remote.
mock = <<~'BASH'
  git() {
    printf '%s\n' "$*" >> "$GIT_LOG"
    case "$1" in
      merge-base)
        if [[ "$3" == "HEAD" ]]; then
          [[ "$SCENARIO" != "diverged" && "$SCENARIO" != "newer" ]]
        else
          [[ "$SCENARIO" != "not-master" && "$SCENARIO" != "missing" ]]
        fi
        ;;
      checkout) [[ "$SCENARIO" != "checkout-failure" ]] ;;
      merge) [[ "$SCENARIO" != "merge-failure" ]] ;;
      rev-parse)
        if [[ "$SCENARIO" == "wrong-head" || ( "$2" == "FETCH_HEAD" && "$SCENARIO" != "push-same" ) ]]; then
          printf '%040d\n' 0
        else
          printf '%s\n' "$DEPLOY_REVISION"
        fi
        ;;
      push) [[ "$SCENARIO" != "push-failure" && "$SCENARIO" != "push-same" && "$SCENARIO" != "fetch-failure" ]] ;;
      fetch) [[ "$SCENARIO" != "fetch-failure" ]] ;;
      *) echo "Unexpected git command: $*" >&2; return 2 ;;
    esac
  }
  export -f git
BASH

cases = [
  ["fixed", revision, "staging", true, nil],
  ["invalid", "master", "staging", false, "full 40-character"],
  ["not-master", revision, "staging", false, "not a commit on origin/master"],
  ["missing", revision, "staging", false, "not a commit on origin/master"],
  ["diverged", revision, "staging", false, "newer than or diverges"],
  ["newer", revision, "staging", false, "newer than or diverges"],
  ["checkout-failure", revision, "staging", false, nil],
  ["merge-failure", revision, "staging", false, nil],
  ["wrong-head", revision, "staging", false, "does not match"],
  ["push-failure", revision, "staging", false, nil],
  ["legacy-staging", "", "staging", true, nil],
  ["legacy-production", "", "production", true, nil],
  ["shared-staging", revision, "volkswagenstaging", true, nil, "staging"],
  ["shared-production", revision, "aktivproduction", true, nil, "production"],
  ["legacy-shared-production", "", "vwfsproduction", true, nil, "production"],
  ["push-same", revision, "vwfsstaging", true, "already points", "staging"],
  ["fetch-failure", revision, "vwfsstaging", false, nil, "staging"]
]

Dir.mktmpdir("deploy-selftest-") do |dir|
  mock_path = File.join(dir, "mock.sh")
  log_path = File.join(dir, "git.log")
  File.write(mock_path, mock)

  cases.each do |scenario, sha, target, success, message, branch|
    branch ||= target
    File.write(log_path, "")
    output, status = Open3.capture2e(
      {
        "BASH_ENV" => mock_path,
        "GITHUB_WORKSPACE" => dir,
        "GIT_LOG" => log_path,
        "SCENARIO" => scenario,
        "DEPLOY_TARGET" => target,
        "DEPLOY_BRANCH" => branch,
        "DEPLOY_REVISION" => sha
      },
      "bash", "-euo", "pipefail", "-c", script
    )
    commands = File.readlines(log_path, chomp: true)
    raise "#{scenario}: unexpected status\n#{output}" unless status.success? == success
    raise "#{scenario}: missing error\n#{output}" if message && !output.include?(message)

    if scenario == "fixed" || scenario.start_with?("shared-")
      expected = [
        "merge-base --is-ancestor #{revision} origin/master",
        "checkout #{branch}",
        "merge-base --is-ancestor HEAD #{revision}",
        "merge --ff-only #{revision}",
        "rev-parse HEAD",
        "push origin HEAD:refs/heads/#{branch}"
      ]
      raise "Fixed revision command sequence changed: #{commands}" unless commands == expected
    elsif scenario.start_with?("legacy-")
      source = branch == "production" ? "staging" : "master"
      expected = ["checkout #{branch}", "merge origin/#{source}", "push"]
      raise "#{scenario}: legacy behavior changed" unless commands == expected
    elsif scenario == "push-same"
      raise "Concurrent push was not verified" unless commands.last(2) == ["fetch origin refs/heads/#{branch}", "rev-parse FETCH_HEAD"]
    elsif !%w[push-failure fetch-failure].include?(scenario)
      raise "#{scenario}: pushed despite failed validation" if commands.any? { |cmd| cmd.start_with?("push") }
    end
    puts "#{scenario}: OK"
  end
end
