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
        if [[ "$SCENARIO" == "wrong-head" ]]; then
          printf '%040d\n' 0
        else
          printf '%s\n' "$DEPLOY_REVISION"
        fi
        ;;
      push) [[ "$SCENARIO" != "push-failure" ]] ;;
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
  ["legacy-production", "", "production", true, nil]
]

Dir.mktmpdir("deploy-selftest-") do |dir|
  mock_path = File.join(dir, "mock.sh")
  log_path = File.join(dir, "git.log")
  File.write(mock_path, mock)

  cases.each do |scenario, sha, target, success, message|
    File.write(log_path, "")
    output, status = Open3.capture2e(
      {
        "BASH_ENV" => mock_path,
        "GITHUB_WORKSPACE" => dir,
        "GIT_LOG" => log_path,
        "SCENARIO" => scenario,
        "DEPLOY_TARGET" => target,
        "DEPLOY_REVISION" => sha
      },
      "bash", "-euo", "pipefail", "-c", script
    )
    commands = File.readlines(log_path, chomp: true)
    raise "#{scenario}: unexpected status\n#{output}" unless status.success? == success
    raise "#{scenario}: missing error\n#{output}" if message && !output.include?(message)

    if scenario == "fixed"
      expected = [
        "merge-base --is-ancestor #{revision} origin/master",
        "checkout staging",
        "merge-base --is-ancestor HEAD #{revision}",
        "merge --ff-only #{revision}",
        "rev-parse HEAD",
        "push origin HEAD:refs/heads/staging"
      ]
      raise "Fixed revision command sequence changed: #{commands}" unless commands == expected
    elsif scenario.start_with?("legacy-")
      source = target == "production" ? "staging" : "master"
      expected = ["checkout #{target}", "merge origin/#{source}", "push"]
      raise "#{scenario}: legacy behavior changed" unless commands == expected
    elsif scenario != "push-failure"
      raise "#{scenario}: pushed despite failed validation" if commands.any? { |cmd| cmd.start_with?("push") }
    end
    puts "#{scenario}: OK"
  end
end
