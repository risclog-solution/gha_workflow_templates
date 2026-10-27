require "yaml"
require "json"
require "tmpdir"
require "open3"

workflow = YAML.safe_load(
  File.read(File.expand_path("../workflows/pin_release.yml", __dir__))
)
call = workflow.fetch("on") { workflow.fetch(true) }.fetch("workflow_call")
raise "Webhook must remain optional" unless call["secrets"]["CHAT_WEBHOOK_URL"]["required"] == false
steps = workflow.fetch("jobs").fetch("pin").fetch("steps")
pin = steps.find { |step| step["id"] == "pin" }
notification = steps.last
raise "Notification must follow pinning" unless steps.index(pin) == steps.size - 2
raise "Notification must be opt-in" unless notification["if"] == "env.CHAT_WEBHOOK_URL != ''"
raise "Notification must use pinning SHA" unless notification["env"]["DEPLOY_REVISION"] == '${{ steps.pin.outputs.revision }}'

Dir.mktmpdir("pin-release-selftest-") do |dir|
  mock = File.join(dir, "mock.sh")
  capture = File.join(dir, "request.json")
  revision = "a" * 40
  File.write(mock, <<~'BASH')
    curl() {
      [[ "$1" == "--fail" ]] || return 2
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "-d" ]]; then
          printf '%s' "$2" > "$CAPTURE"
          shift
        fi
        if [[ $# == 1 ]]; then
          [[ "$1" == "$CHAT_WEBHOOK_URL" ]] || return 3
        fi
        shift
      done
      return "$CURL_STATUS"
    }
    export -f curl
  BASH
  env = {
    "BASH_ENV" => mock,
    "CAPTURE" => capture,
    "CURL_STATUS" => "0",
    "CHAT_WEBHOOK_URL" => "https://chat.example.invalid/webhook/test",
    "DEPLOY_REVISION" => revision,
    "GITHUB_SERVER_URL" => "https://github.com",
    "PACKAGE" => "example-package",
    "VERSION" => "1.2.3"
  }
  %w[kravagonline_deployment another_deployment].each do |repository|
    _, status = Open3.capture2e(env.merge("DEPLOY_REPOSITORY" => repository),
                              "bash", "-euo", "pipefail", "-c", notification["run"])
    raise "Notification failed for #{repository}" unless status.success?
    text = JSON.parse(File.read(capture)).fetch("text")
    command = "gh workflow run deploy-release.yml --repo risclog-solution/#{repository} --ref master -f revision=#{revision}"
    raise "Wrong deployment command" unless text.include?("```\n#{command}\n```")
    raise "Missing commit link" unless text.include?("https://github.com/risclog-solution/#{repository}/commit/#{revision}")
    raise "Missing release version" unless text.include?("example-package 1.2.3")
  end
  ["http://chat.example.invalid/webhook/test", "https://"].each do |url|
    _, status = Open3.capture2e(env.merge("DEPLOY_REPOSITORY" => "another_deployment", "CHAT_WEBHOOK_URL" => url),
                              "bash", "-euo", "pipefail", "-c", notification["run"])
    raise "Invalid webhook accepted" if status.success?
  end
  _, status = Open3.capture2e(env.merge("DEPLOY_REPOSITORY" => "another_deployment", "CURL_STATUS" => "22"),
                            "bash", "-euo", "pipefail", "-c", notification["run"])
  raise "HTTP error ignored" if status.success?
end
puts "Pinning notification: generic repository, exact SHA, opt-in, JSON payload and HTTP errors OK"
