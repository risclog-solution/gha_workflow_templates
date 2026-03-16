#!/usr/bin/env ruby

require "yaml"

def detect_config_path
  [".pre-commit-config.yaml", ".pre-commit-config.yml"].find { |path| File.exist?(path) }
end

def normalize_python_version(raw_value)
  return nil if raw_value.nil?

  value = raw_value.to_s.strip
  return nil if value.empty?

  case value.downcase
  when "default", "system"
    nil
  when /\A\d+(?:\.\d+){0,2}\z/
    value
  when /\Apython(\d+(?:\.\d+){0,2})\z/i
    Regexp.last_match(1)
  when /\Apython(?:3)?\z/i
    "3.x"
  else
    nil
  end
end

def load_config(path)
  YAML.safe_load(File.read(path), aliases: false) || {}
rescue Errno::ENOENT
  warn "Failed to read #{path}: file not found"
  exit 1
rescue Psych::Exception => error
  warn "Failed to parse #{path}: #{error.message}"
  exit 1
end

def collect_hook_python_versions(config)
  repos = config.fetch("repos", [])
  return [] unless repos.is_a?(Array)

  repos.flat_map do |repo|
    next [] unless repo.is_a?(Hash)

    hooks = repo["hooks"]
    next [] unless hooks.is_a?(Array)

    hooks.filter_map do |hook|
      next unless hook.is_a?(Hash)

      raw_version = hook["language_version"]
      normalized_version = normalize_python_version(raw_version)
      next if normalized_version.nil?

      {
        "id" => hook["id"] || "<unknown>",
        "raw_version" => raw_version.to_s,
        "normalized_version" => normalized_version,
      }
    end
  end
end

def emit_result(version:, source:, config_path:)
  puts "python-version=#{version}"
  puts "source=#{source}"
  puts "config-path=#{config_path}"
end

default_python_version = ENV.fetch("DEFAULT_PYTHON_VERSION", "3.9")
input_python_version = ENV.fetch("INPUT_PYTHON_VERSION", "").strip
config_path = ARGV[0] || detect_config_path || ""

unless input_python_version.empty?
  resolved_input_version = normalize_python_version(input_python_version) || input_python_version
  emit_result(
    version: resolved_input_version,
    source: "workflow input",
    config_path: config_path,
  )
  exit 0
end

if config_path.empty?
  emit_result(
    version: default_python_version,
    source: "default fallback",
    config_path: "",
  )
  exit 0
end

config = load_config(config_path)
unless config.is_a?(Hash)
  warn "Invalid pre-commit config in #{config_path}: expected a top-level mapping"
  exit 1
end

default_language_python_raw = config.dig("default_language_version", "python")
default_language_python = normalize_python_version(default_language_python_raw)
hook_python_versions = collect_hook_python_versions(config)
unique_hook_versions = hook_python_versions.map { |entry| entry["normalized_version"] }.uniq

if unique_hook_versions.length > 1
  details = hook_python_versions.map do |entry|
    "#{entry["id"]}=#{entry["raw_version"]}"
  end.join(", ")
  warn "Multiple Python language_version values found in #{config_path}: #{details}"
  exit 1
end

if default_language_python && !unique_hook_versions.empty? && unique_hook_versions.first != default_language_python
  warn(
    "Conflicting Python versions found in #{config_path}: " \
    "default_language_version.python=#{default_language_python_raw} " \
    "and hook language_version=#{hook_python_versions.first["raw_version"]}"
  )
  exit 1
end

if default_language_python
  emit_result(
    version: default_language_python,
    source: "default_language_version.python",
    config_path: config_path,
  )
  exit 0
end

if unique_hook_versions.length == 1
  emit_result(
    version: unique_hook_versions.first,
    source: "hook language_version",
    config_path: config_path,
  )
  exit 0
end

emit_result(
  version: default_python_version,
  source: "default fallback",
  config_path: config_path,
)
