require 'net/http'
require 'openssl'
require 'json'

require_relative 'gitlab_config'
require_relative 'gitlab_logger'
require_relative 'gitlab_access'
require_relative 'gitlab_lfs_authentication'
require_relative 'httpunix'
require_relative 'http_helper'

class GitlabNet # rubocop:disable Metrics/ClassLength
  include HTTPHelper

  class ApiUnreachableError < StandardError; end
  class NotFound < StandardError; end

  CHECK_TIMEOUT = 5
  GL_PROTOCOL = 'ssh'.freeze

  def check_access(cmd, gl_repository, repo, actor, changes, protocol, env: {})
    changes = changes.join("\n") unless changes.is_a?(String)

    params = {
      action: cmd,
      changes: changes,
      gl_repository: gl_repository,
      project: sanitize_path(repo),
      protocol: protocol,
      env: env
    }

    if actor =~ /\Akey\-\d+\Z/
      params[:key_id] = actor.gsub("key-", "")
    elsif actor =~ /\Auser\-\d+\Z/
      params[:user_id] = actor.gsub("user-", "")
    end

    url = "#{internal_api_endpoint}/allowed"
    resp = post(url, params)

    if resp.code == '200'
      GitAccessStatus.create_from_json(resp.body)
    else
      GitAccessStatus.new(false,
                          'API is not accessible',
                          gl_repository: nil,
                          gl_username: nil,
                          repository_path: nil,
                          gitaly: nil)
    end
  end

  def discover(key)
    key_id = key.gsub("key-", "")
    resp = get("#{internal_api_endpoint}/discover?key_id=#{key_id}")
    JSON.parse(resp.body) rescue nil
  end

  def lfs_authenticate(key, repo)
    params = {
      project: sanitize_path(repo),
      key_id: key.gsub('key-', '')
    }

    resp = post("#{internal_api_endpoint}/lfs_authenticate", params)

    if resp.code == '200'
      GitlabLfsAuthentication.build_from_json(resp.body)
    end
  end

  def broadcast_message
    resp = get("#{internal_api_endpoint}/broadcast_message")
    JSON.parse(resp.body) rescue {}
  end

  def merge_request_urls(gl_repository, repo_path, changes)
    changes = changes.join("\n") unless changes.is_a?(String)
    changes = changes.encode('UTF-8', 'ASCII', invalid: :replace, replace: '')
    url = "#{internal_api_endpoint}/merge_request_urls?project=#{URI.escape(repo_path)}&changes=#{URI.escape(changes)}"
    url += "&gl_repository=#{URI.escape(gl_repository)}" if gl_repository
    resp = get(url)

    if resp.code == '200'
      JSON.parse(resp.body)
    else
      []
    end
  rescue
    []
  end

  def check
    get("#{internal_api_endpoint}/check", options: { read_timeout: CHECK_TIMEOUT })
  end

  def authorized_key(key)
    resp = get("#{internal_api_endpoint}/authorized_keys?key=#{URI.escape(key, '+/=')}")
    JSON.parse(resp.body) if resp.code == "200"
  rescue
    nil
  end

  def two_factor_recovery_codes(key)
    key_id = key.gsub('key-', '')
    resp = post("#{internal_api_endpoint}/two_factor_recovery_codes", key_id: key_id)

    JSON.parse(resp.body) if resp.code == '200'
  rescue
    {}
  end

  def notify_post_receive(gl_repository, repo_path)
    params = { gl_repository: gl_repository, project: repo_path }
    resp = post("#{internal_api_endpoint}/notify_post_receive", params)

    resp.code == '200'
  rescue
    false
  end

  def post_receive(gl_repository, identifier, changes)
    params = {
      gl_repository: gl_repository,
      identifier: identifier,
      changes: changes
    }
    resp = post("#{internal_api_endpoint}/post_receive", params)

    raise NotFound if resp.code == '404'

    JSON.parse(resp.body) if resp.code == '200'
  end

  def pre_receive(gl_repository)
    resp = post("#{internal_api_endpoint}/pre_receive", gl_repository: gl_repository)

    raise NotFound if resp.code == '404'

    JSON.parse(resp.body) if resp.code == '200'
  end

  protected

  def sanitize_path(repo)
    repo.delete("'")
  end
end
