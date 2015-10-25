require "net/http"
require "json"

# TODO
#
# Github
# - critical bugs
#
# Snap CI
#
# - Test status
# - # commits since releas
# - pending QA, Done tasks
#
# Code climate
#
# Other Operations Metrics?

Struct.new "Data", :in_progress, :pull_requests, :dynos_down
$data = Struct::Data.new(*Array.new(3, 0))
$warn_treshold = Struct::Data.new 2, 1, 1
$crit_treshold = Struct::Data.new 3, 3, 1

$heroku_token = ENV.fetch('HEROKU_TOKEN')
$github_token = ENV.fetch('GITHUB_TOKEN')

# GITHUB

def get(uri)
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    req = Net::HTTP::Get.new uri
    req["Accept"] = "application/vnd.github.v3+json"
    req['Authorization'] = "token #$github_token"

    response = http.request req
    raise response.error! unless response.code == "200"
    body = JSON.parse response.body
    if block_given?
      yield body
    else
      body
    end
  end
end

repos_url = get URI("https://api.github.com/orgs/gramo-org") do |resp|
  resp["repos_url"]
end

repos = get URI(repos_url)

repos.each do |repo|
  url = repo['issues_url'].sub(/\{\/number\}/, '')
  get URI(url) do |resp|
    $data.in_progress += resp.count { |i| i["labels"].find {|l| l["name"] == "in progress" }}
  end

  url = repo['pulls_url'].sub(/\{\/number\}/, '')
  get URI(url) do |resp|
    $data.pull_requests += resp.count
  end
end

# HEROKU

def heroku_get(uri)
  http = Net::HTTP.new uri.host, uri.port
  http.use_ssl = true
  #http.set_debug_output $stderr
  http.start do |http|
    req = Net::HTTP::Get.new uri
    req["Accept"] = "application/vnd.heroku+json; version=3"
    req['Authorization'] = "Bearer #$heroku_token"



    response = http.request req
    raise response.error! unless response.code == "200"

    # FIXME why?
    body = if response.key?("content-encoding")
             Zlib::GzipReader.new(StringIO.new(response.body)).read
           else
             response.body
           end
    body = JSON.parse body
    if block_given?
      yield body
    else
      body
    end
  end
end


apps = heroku_get URI("https://api.heroku.com/apps") do |resp|
  resp.find_all { |app| app["name"].start_with? "gramo" }
end

apps.each do |app|
  uri = URI("https://api.heroku.com/apps/#{app["name"]}/dynos")
  heroku_get uri  do |resp|
    $data.dynos_down += resp.count { |d| not %w(idle up).include? d["state"] }
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

print_metric "Stories in progress", :in_progress
print_metric "Pull requests",       :pull_requests
print_metric "Dynos down",          :dynos_down
