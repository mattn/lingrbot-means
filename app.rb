# encoding: utf-8

require 'bundler'
Bundler.require

require 'sinatra/reloader' if development?

LingrBot.configure do |config|
  config.id     = ENV['BOT_ID']
  config.secret = ENV['BOT_SECRET']
end

class Bot < Sinatra::Base

  configure :development do
    register Sinatra::Reloader
  end

  def initialize *args
    init_mechanize
    init_redis
    init_twitter
    init_pixiv
    spawn_worker
    super
  end

  post '/' do
    enqueue *JSON.parse(request.body.read)['events'].map{ |e|
      e['message']
    }
    content_type :text
    ''
  end

  get '/' do
    content_type :text
    'Still Alive'
  end

  private
  def init_mechanize
    @agent = Mechanize.new
    @agent.verify_mode = OpenSSL::SSL::VERIFY_NONE
    @agent.user_agent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_9_4) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/38.0.2125.0 Safari/537.36'
    @agent.request_headers = {
      'Accept-Encoding' => 'gzip,deflate,sdch',
      'Accept-Language' => 'ja,en-US;q=0.8,en;q=0.6'
    }
  end

  def init_redis
    uri = URI.parse ENV['REDISCLOUD_URL'] || 'redis://localhost:6379'
    @redis = Redis.new host: uri.host, port: uri.port, password: uri.password
  end

  def init_twitter
    @twitter = Twitter::REST::Client.new do |config|
      config.consumer_key        = ENV['TWITTER_CONSUMER_KEY']
      config.consumer_secret     = ENV['TWITTER_CONSUMER_SECRET']
      config.access_token        = ENV['TWITTER_ACCESS_TOKEN']
      config.access_token_secret = ENV['TWITTER_ACCESS_SECRET']
    end
  end

  def init_pixiv
    @pixiv = Pixiv.client ENV['PIXIV_ID'], ENV['PIXIV_PASSWORD'] do |config|
      config.user_agent_alias = 'Mac Safari'
    end
  end

  def init_queues
    puts "Initialize queues." unless @queues
    @queues ||= []
  end

  def enqueue message
    puts "Enqueued."
    @queues.push message
  end

  def dequeue
    puts "Dequeued."
    @queues.shift
  end

  def spawn_worker
    init_queues
    EM:: defer do
      loop do
        sleep 0.5
        next if @queues.empty?
        begin
          handle_message dequeue
        rescue => e
          puts "Got error: #{e}"
        end
      end
    end
  end

  def handle_message message
    response =
      case message['text']
      when /^ping$/
        'pong'
      when %r`http://(?:www\.nicovideo\.jp/watch|nico\.ms)/(sm\d+)`
        nicovideo($1)
      when %r`http://live\.nicovideo\.jp/gate/(lv\d+)`
        nicolive_gate($1)
      when %r`http://(?:www|touch)?\.pixiv\.net/member\.php\?id=(\d+)`
        pixiv_member($1)
      when %r`https://twitter\.com/[^\/]+/status(?:es)?/(\d+)(?:\/photo\/\d+)?$`
        twitter_media_url($1.to_i)
      when %r`http://d\.pr/i/(\w+)$`
        droplr_raw_url($1)
      when %r`http://seiga\.nicovideo\.jp/seiga/im(\d+)`
        nicoseiga_image_url($1.to_i)
      when %r`(http://seiga\.nicovideo\.jp/watch/mg\d+)`
        nicoseiga_comic_thumb_url($1)
      when %r`(http://seiga\.nicovideo\.jp/comic/\d+)`
        nicoseiga_comic_main_url($1)
      when %r`(http://gyazo\.com/\w+)$`
        gyazo_raw_url($1)
      when %r`http://ow\.ly/i/(\w+)`
        owly_raw_url($1)
      end
    say message['room'], response if response
    puts "Didn't match." unless response
  end

  def say room_id, message
    puts "say to `#{room_id}`:"
    LingrBot.say(room_id, message)
  end

  def gyazo_raw_url(url)
    res = @agent.get url
    res.at('meta[name="twitter:image"]').attr 'content' if res.code == '200'
  end

  def droplr_raw_url(id)
    # Official raw url format is `http://d.pr/i/#{id}+`
    # but use another way for client compatibility.
    "http://d.pr/i/#{id}.png"
  end

  def twitter_media_url(status_id)
    s = @twitter.status status_id
    s.media.map(&:media_url_https).join("\n") if s.media?
  end

  def pixiv_member(id)
    member = @pixiv.member(id)
    member.profile_image_url
  end

  def nicolive_gate(id)
    res = @agent.get "http://live.nicovideo.jp/gate/#{id}"
    res.at('meta[property="og:image"]').attr('content') if res.code == '200'
  end

  def nicovideo(id)
    res = @agent.get "http://ext.nicovideo.jp/api/getthumbinfo/#{id}"
    "%s.L#.jpg" % res.at('thumbnail_url').inner_text if res.code == '200'
  end

  def nicoseiga_image_url(id)
    "http://lohas.nicoseiga.jp/thumb/#{id}i#.png"
  end

  def nicoseiga_comic_thumb_url(url)
    res = @agent.get url
    "%s#.png" % res.at('meta[property="og:image"]').attr('content') if res.code == '200'
  end

  def nicoseiga_comic_main_url(url)
    res = @agent.get url
    "%s#.png" % res.at('.main_visual img').attr('src') if res.code == '200'
  end

  def owly_raw_url(id)
    # ow.ly will convert all image types to jpg
    "http://static.ow.ly/photos/normal/#{id}.jpg"
  end

end
