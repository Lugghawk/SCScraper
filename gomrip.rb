require 'rubygems'
require 'httpclient'
require 'json'
require 'pp'
require 'socket'
require 'cgi'
require 'nokogiri'
require 'fileutils'
require 'yaml'

$base_url = 

class GomRipper

  def initialize(config)
  
    @config = config #replace with some sort of Defaults.merge(config)?
    @http = HTTPClient.new
    @cookie = nil
    @debug = false
  end

  attr_accessor :config

  def debug s
    return unless @config[:debug]
    puts s
  end

  def nextUrl(content)
    debug "getting next url"
    nextfinder = Regexp.new("onclick=\"getPrevNext\\(('next'.*)\\)")
    m = content.match(nextfinder)
    
    params = m[1].split(",").map{|s| s.delete(" '")}
    
    debug "params: #{params.inspect}"
    
    dir = params[0]
    conid = params[1]
    menuid = params[2]
    baseurl = params[3]
    cid = params[4]
    subtype = params[5] ? params[5] : ''
    url = "/process/rd.gom?dir="+dir+"&conid="+conid+"&menuid="+menuid +"&cid="+cid+"&subtype="+subtype
    debug "ajax url: #{@config[:base_url] + url}"
    res = @http.get(@config[:base_url] + url)
    
    return nil if res.content.length == 0
    return baseurl + res.content
    
  end

  def login
    url = "/user/loginProcess.gom"
    data = "mb_username=" + @config[:username] + "&mb_password=" + @config[:password] + "&cmd=login&rememberme=0"
    res = @http.post(@config[:base_url] + url, data)
  end

  def get_page(url)
   return @http.get(url).content
  end
  
  def get_flash_intermediate_urls(content)
    r = Regexp.new("\\{'vjoinid':([\\d]*)\\}")
    joinids = content.scan(r).flatten
    player_info = get_player_info(content)
    
    urls = joinids.map do |j|
      "http://www.gomtv.net/gox/gox.gom?" + 
        player_info.merge({"vjoinid" => j, "strLevel" => "HQ"}).reduce("") do |memo, obj|
          memo << CGI::escape(obj[0]) + "=" + CGI::escape(obj[1]) + "&"
        end
    end
  end
  
  def get_player_info(content)
    r = Regexp.new("this.playObj\\s*=\\s*\\{(.+?)(?:,[^,]*)\\};", Regexp::MULTILINE)
    player_info = JSON.parse("{" + content.match(r)[1] + "}")
  end

  def get_vod_url(intermediate_url)
    debug "getting vod information from: #{intermediate_url}"
    gox = @http.get(intermediate_url).content
    doc = Nokogiri.XML(gox)
    uno = doc.xpath("//UNO/text()")[0].to_s
    nodeid = doc.xpath("//NODEID/text()")[0].to_s
    nodeip = doc.xpath("//NODEIP/text()")[0].to_s
    userip = doc.xpath("//USERIP/text()")[0].to_s
    
    req = ["Login","0",uno,nodeid,userip].join(",")
    begin
      s = TCPSocket.open(nodeip, 63800)
    rescue Errno::ECONNREFUSED
      puts "Connection refused to #{nodeip}:63800"
      raise $!
    end  
    s.puts req
    line = s.gets
    s.close
    
    key = line.split(",").last.chomp
    
    baseurl = doc.xpath("//@href")[0].to_s
    
    return baseurl + "&key=" + key
    
  end

  def spoilerfree_fetch
    debug "logging in"
    self.login
    nexturl = @config[:start]
    finished = false
    Dir.chdir(@config[:dump_dir]) do
      while not finished
        finished = true if nexturl == @config[:end] #last one, but grab all the vods
        id = nexturl.split("/").last
        debug "id: #{id}"
        
        FileUtils.mkdir(id) unless File.exists?(id)
        content = get_page(nexturl)
        Dir.chdir(id) do
          debug "changing dir to #{id}"
          intermediates = get_flash_intermediate_urls(content)
          count = 1
          intermediates.each do |i|
            FileUtils.mkdir(count.to_s) unless File.exists?(count.to_s)
            Dir.chdir(count.to_s) do
              debug "changing dir to #{count.to_s}"
              if not File.exists?("game.mpg")
                dl = get_vod_url(i)
                debug "vod url: #{dl}"
                `wget -O game.mpg '#{dl}'`
              else
                debug "file already exists"
              end
            end
            count = count + 1
          end
        end
        nexturl = self.nextUrl(content) unless finished
        debug "next url: #{nexturl}"
        break if nexturl.nil?
      end
    end
  end
end

if __FILE__ == $0
  g = GomRipper.new(YAML.load_file("config.yml"))
  g.spoilerfree_fetch
  
end
