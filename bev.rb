# coding: utf-8
require "net/http"
require "json"

# TODO
#
# Github
# - critical bugs
#
# Snap CI
#
# - # commits since release
# - pending QA, Done tasks
#
# Code climate
#
# Other Operations Metrics?

$metrics = :in_progress, :pull_requests, :dynos_down, :failing_pipelines, :todos
Struct.new "Data", *$metrics
$data = nil
$warn_treshold = Struct::Data.new 2, 1, 1, 1, 1
$crit_treshold = Struct::Data.new 3, 3, 1, 1, 5

$heroku_token = ENV.fetch('HEROKU_TOKEN')
$github_token = ENV.fetch('GITHUB_TOKEN')
$snapci_token = ENV.fetch('SNAPCI_TOKEN')

def reset_data
  $data = Struct::Data.new(*Array.new($metrics.length, 0))
end

def get(uri, req_proc, res_proc)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    req = Net::HTTP::Get.new uri
    req_proc.(req)
    response = http.request req
    raise response.error! unless response.code == "200"

    body = JSON.parse res_proc.(response)
    if block_given?
      yield body
    else
      body
    end
  end
end

def github_get(uri, &block)
  get(uri, ->(req) {
        req["Accept"] = "application/vnd.github.v3+json"
        req['Authorization'] = "token #$github_token"
      }, ->(res) {res.body}, &block)
end

def heroku_get(uri, &block)
  get(uri, ->(req) {
        req["Accept"] = "application/vnd.heroku+json; version=3"
        req['Authorization'] = "Bearer #$heroku_token"
      }, ->(res) {
        # FIXME why?
        if res.key?("content-encoding")
          Zlib::GzipReader.new(StringIO.new(res.body)).read
        else
          res.body
        end
      }, &block)
end

def snapci_get(uri)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    req = Net::HTTP::Get.new uri
    req["Accept"] = "application/vnd.snap-ci.com.v1+json"
    req.basic_auth "kjellm", $snapci_token

    response = http.request req
    if response.code == "302"
    end
    raise response.error! unless response.code == "200"
    body = JSON.parse response.body
    if block_given?
      yield body
    else
      body
    end
  end
end

def ansi_bg(metric)
  case
  when $data[metric] >= $crit_treshold[metric]
    "\e[41m"
  when $data[metric] >= $warn_treshold[metric]
    "\e[43m"
  else
    "\e[42m"
  end
end

def ansi_clear
  "\e[0m"
end

def print_metric(text, metric)
  puts "#{text}:".ljust(30) << ansi_bg(metric) << $data[metric].to_s.rjust(4) << " " << ansi_clear
end

def write_summary_to_file
  summary = { ok: 0, warn: 0, crit: 0 }
  open '/tmp/bev', 'w' do |io|
    $metrics.each do |metric|
      key = case
            when $data[metric] >= $crit_treshold[metric]
              :crit
            when $data[metric] >= $warn_treshold[metric]
              :warn
            else
              :ok
            end
      summary[key] += 1
    end
    io.puts "ok #{summary[:ok]}"
    io.puts "warn #{summary[:warn]}"
    io.puts "crit #{summary[:crit]}"
  end
end

def print_banner
  puts <<EOT
┌────────────────────────────────────┐
│          Bird's Eye View           │▒
└────────────────────────────────────┘▒
  ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒

EOT
end

def print_metrics
  print_metric "Stories in progress", :in_progress
  print_metric "Pull requests",       :pull_requests
  print_metric "Dynos down",          :dynos_down
  print_metric "Failed pipelines",    :failing_pipelines
  print_metric "Todo comments",       :todos
end

def gather_data
  threads = []

  # GITHUB
  repos_url = github_get URI("https://api.github.com/orgs/gramo-org") do |resp|
    resp["repos_url"]
  end
  github_repos = github_get URI(repos_url)

  threads << Thread.new do
    github_repos.each do |repo|
      url = repo['issues_url'].sub(/\{\/number\}/, '')
      github_get URI(url) do |resp|
        $data.in_progress += resp.count do |r|
          r["labels"].find {|l| l["name"] == "in progress" } \
          && r["labels"].find {|l| l["name"] == "feature" }
        end
      end

      url = repo['pulls_url'].sub(/\{\/number\}/, '')
      github_get URI(url) do |resp|
        $data.pull_requests += resp.count
      end
    end
  end

  # HEROKU
  threads << Thread.new do
    apps = heroku_get URI("https://api.heroku.com/apps") do |resp|
      resp.find_all { |app| app["name"].start_with? "gramo" }
    end

    apps.each do |app|
      uri = URI("https://api.heroku.com/apps/#{app["name"]}/dynos")
      heroku_get uri  do |resp|
        $data.dynos_down += resp.count { |d| not %w(idle up).include? d["state"] }
      end
    end
  end


  # SNAP CI
  threads << Thread.new do
    github_repos.each do |repo|
      latest_url = begin
                     snapci_get URI("https://api.snap-ci.com/project/#{repo['full_name']}/branch/master/pipelines/latest") do |resp|
                       resp["_links"]["redirect"]["href"]
                     end
                   rescue
                     next
                   end

      snapci_get URI(latest_url) do |resp|
        $data.failing_pipelines += 1 if resp['result'] != 'passed'
      end
    end
  end

  # TODOS
  threads << Thread.new do
    ignore = %w(.bundle bower_components dist tmp)
    ignore = [''].concat(ignore).join(" --ignore-dir=")
    pattern = "FIX|TODO"
    $data.todos = `ack --no-filename --count #{ignore} "#{pattern}"`.to_i
  end

  threads.each { |thread| thread.join }
end

def main
  reset_data
  write_summary_to_file
  system("clear")
  print_banner
  gather_data
  print_metrics
end

while true do
  main
  sleep 60
end
