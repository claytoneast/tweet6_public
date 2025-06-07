# had to export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/local/opt/openssl/lib/pkgconfig
# to run this, `$ crystal run hello_world.cr`. Might need to export the bearer
# token first which is in the gitignore'd secrets file.

require "http/client"
require "json"
require "ecr"

TOKEN = ENV["BEARER_TOKEN"]

USER_DATA_PATH = "./user_data.json"
MEGALIST_PATH  = "./megalist.json"

struct TimelineResponse
  include JSON::Serializable

  @[JSON::Field(key: "data")]
  property tweets : Array(Tweet)?

  property meta : TimelineMeta
  property includes : IncludedData?
end

struct ListTweetsResponse
  include JSON::Serializable

  @[JSON::Field(key: "data")]
  property tweets : Array(Tweet)?

  property includes : IncludedData?
end

struct IncludedData
  include JSON::Serializable

  property users : Array(IncludedUserData)
  property media : Array(Media)?
end

struct Media
  include JSON::Serializable

  property media_key : String
  property type : String
  # url is optional as only some media actually have them, videos for instance
  # do not.
  property url : String?
end

struct IncludedUserData
  include JSON::Serializable

  property id : String
  property name : String
  property username : String
end

struct TimelineMeta
  include JSON::Serializable

  property next_token : String?
  property previous_token : String?
  # I think results can only be up to 100 tweets at a time, hence Int8
  property result_count : Int8?
end

struct ReferencedTweet
  include JSON::Serializable

  property type : String
  property id : String
end

struct Attachments
  include JSON::Serializable

  property media_keys : Array(String)
end

class Tweet
  include JSON::Serializable

  property id : String
  property text : String
  property created_at : String
  property author_id : String
  property referenced_tweets : Array(ReferencedTweet)?
  property name : String?
  property username : String?
  property attachments : Attachments?
  property medias : Array(Media)?

  def initialize(
    @id : String,
    @text : String,
    @created_at : String,
    @author_id : String,
    @referenced_tweets : Array(ReferencedTweet)?,
    @name : String?,
    @username : String?,
    @attachments : Attachments?,
    @medias : Array(Media)?
  )
  end
end

def get_timeline_data(user_id : String, next_token : String | Nil = nil)
  # date strings must be in https://www.rfc-editor.org/rfc/rfc3339#page-10 format
  # aka iso 8601
  start_time = Time::Format::ISO_8601_DATE_TIME.format(
    Time.utc - Time::Span.new(days: 5)
  )
  timeline_url = "https://api.twitter.com/2/users/#{user_id}/tweets?"
  params = {
    "start_time"   => start_time,
    "max_results"  => "100",
    "tweet.fields" => "id,created_at,text,author_id,referenced_tweets",
    "expansions"   => "author_id,attachments.media_keys",
    "user.fields"  => "name,username",
    "media.fields" => "type,url",
  }
  if next_token
    params["pagination_token"] = next_token
  end

  paramStr = HTTP::Params.encode(params)
  url = timeline_url + paramStr
  response = HTTP::Client.get(
    url,
    headers: HTTP::Headers{"User-Agent" => "v2UserLookupJS", "Authorization" => "Bearer #{TOKEN}"}
  )

  p!(response)
  if response.status_code != 200
    raise Exception.new(message: "failure to get timeline: #{response.status_message}")
  end

  return TimelineResponse.from_json(response.body)
end

def timeline_data(user_id) : Array(Tweet)
  all_timeline_tweets = [] of Tweet
  first_response = get_timeline_data(user_id)
  # calling first_response.tweets results in a runtime error if there are
  # no tweets in the response, hence early return if meta says no results
  if first_response.meta.result_count == 0
    return all_timeline_tweets
  end

  # 1532575012183363584 # what the fuck is happening with this tweet

  all_timeline_tweets = enrich_db_tweets_with_included_data(first_response)

  next_token = first_response.meta.next_token

  while next_token
    next_response = get_timeline_data(user_id, next_token)
    if next_response.meta.result_count == 0
      break
    end

    next_response_tweets = enrich_db_tweets_with_included_data(next_response)
    # all_timeline_tweets += next_response_tweets
    next_response_tweets.each do |d|
      all_timeline_tweets << d
    end

    next_token = next_response.meta.next_token
  end

  return all_timeline_tweets
end

class UsernameNotFound < Exception; end

def user_profile(username)
  paramStr = HTTP::Params.encode({
    "usernames" => username,
  })

  response = HTTP::Client.get(
    "https://api.twitter.com/2/users/by?" + paramStr,
    headers: HTTP::Headers{"User-Agent" => "v2UserLookupJS", "Authorization" => "Bearer #{TOKEN}"}
  )

  if response.status_code != 200
    raise UsernameNotFound.new(message: "Username not found")
  end

  body = JSON.parse(response.body).as_h
  user_data = body["data"][0]
  return user_data
end

def id_from_username(username)
  id_mapping = user_data_from_f()

  if !id_mapping.has_key?(username)
    user_data = user_profile(username)
    user_id = user_data["id"].as_s
    id_mapping[username] = UserData.from_json({"id" => user_id, "timeline" => [] of String}.to_pretty_json)
    File.write(USER_DATA_PATH, id_mapping.to_json)
  end

  return id_mapping[username].id
end

struct UserData
  include JSON::Serializable

  property id : String
  property timeline : Array(String)
end

def user_data_from_f
  if File.exists?(USER_DATA_PATH)
    File.open(USER_DATA_PATH) do |file|
      return Hash(String, UserData).from_json(file)
    end
  else
    File.write(USER_DATA_PATH, "{}")
    return Hash(String, UserData).new
  end
end

# we overwrite the timeline each run as we are only interested in what has
# happened in the last 3 days (or whatever I set the start_time to).
def save_tweets_to_timeline_list(tweets : Array(Tweet), username : String)
  tweet_ids = tweets.map { |t| t.id }
  all_user_data = user_data_from_f()
  if !all_user_data.has_key?(username)
    raise Exception.new(message: "Username:#{username} not found")
  end

  our_user = all_user_data[username]
  our_user.timeline = tweet_ids

  all_user_data[username] = our_user
  File.write(USER_DATA_PATH, all_user_data.to_pretty_json)
end

def get_megalist_data
  data : Hash(String, Tweet)
  if File.exists?(MEGALIST_PATH)
    data = Hash(String, Tweet).from_json(File.open(MEGALIST_PATH))
  else
    File.write(MEGALIST_PATH, "{}")
    data = Hash(String, Tweet).new
  end

  return data
end

def save_tweets_to_megalists(tweets : Array(Tweet))
  megalist_tweet_data = get_megalist_data

  tweets.each do |tweet|
    next if megalist_tweet_data.has_key?(tweet.id)

    megalist_tweet_data[tweet.id] = tweet
  end

  File.write(MEGALIST_PATH, megalist_tweet_data.to_pretty_json)
end

def id_set_from_megalist
  megalist_tweet_data = get_megalist_data
  return Set(String){*megalist_tweet_data.keys}
end

def get_tweets_by_id(tweet_ids : Array(String)) : Array(Tweet)
  all_fetched_tweets = [] of Tweet
  tweet_ids.each_slice(100) do |id_slice|
    params = {
      "ids"          => id_slice.join(","),
      "tweet.fields" => "id,created_at,text,author_id,referenced_tweets",
      "expansions"   => "author_id,attachments.media_keys",
      "user.fields"  => "name,username",
      "media.fields" => "type,url",
    }
    response = HTTP::Client.get(
      "https://api.twitter.com/2/tweets?" + HTTP::Params.encode(params),
      headers: HTTP::Headers{
        "User-Agent"    => "v2UserLookupJS",
        "Authorization" => "Bearer #{TOKEN}",
      }
    )

    if response.status_code != 200
      p!(response)
      raise Exception.new(message: "failure to get timeline: #{response.status_message}")
    end

    resp = ListTweetsResponse.from_json(response.body)
    resp_tweets = enrich_db_tweets_with_included_data(resp)
    all_fetched_tweets += resp_tweets
  end

  return all_fetched_tweets
end

def enrich_db_tweets_with_included_data(resp : ListTweetsResponse | TimelineResponse)
  resp_tweets = resp.tweets
  included_data = resp.includes
  # sometimes there isn't data from the timeline endpoint, because everything
  # has been quote-tweets.
  if resp_tweets.nil? || included_data.nil?
    return [] of Tweet
  end

  included_user_data = included_data.users
  if !included_user_data.nil?
    author_id_to_data = included_data.users.index_by { |x| x.id }

    resp_tweets.each do |tweet|
      tweet.username = author_id_to_data[tweet.author_id].username
      tweet.name = author_id_to_data[tweet.author_id].name
    end
  end

  included_media_data = included_data.media
  if !included_media_data.nil?
    media_key_to_data = included_media_data.index_by { |x| x.media_key }

    # tweet.attachments.media_keys
    resp_tweets.each do |tweet|
      # loop on tweet media
      tweet_attachments = tweet.attachments
      # if the tweet has some attachments, then "copy" the media fields from the
      # media expansion over onto the Tweet struct
      if !tweet_attachments.nil?
        tweet_attachments.media_keys.each do |media_key|
          media_key_was_in_response = media_key_to_data.has_key?(media_key)
          if media_key_was_in_response
            tweet_medias = tweet.medias
            if tweet_medias
              tweet_medias.push(media_key_to_data[media_key])
            else
              tweet.medias = [media_key_to_data[media_key]]
            end
          else
            raise "Couldn't find media key #{media_key} for tweet #{tweet.id}"
          end
        end
      end
    end
  end

  return resp_tweets
end

def get_all_parent_tree_tweets(tweets)
  all_parent_tweets = [] of Tweet
  next_tweet_ids_to_fetch = [] of String

  tweets.each do |tweet|
    ref_tweets = tweet.referenced_tweets
    if ref_tweets
      p! ref_tweets

      # possibly types: retweeted, quoted, replied_to. Handle only replied_to
      # and quoted right now, rest later.
      parent_tweet = ref_tweets.select { |x|
        x.type == "replied_to" || x.type == "quoted"
      }

      if parent_tweet.size > 1
        p! "------------ there are more than 1 referenced tweets!!!!!!!!!!!!!"
      end

      # serious problem if there is more than 1 ref tweet, but we'll handle that
      # later.
      if parent_tweet.size > 0
        next_tweet_ids_to_fetch << parent_tweet.first.id
      end
    end
  end

  # base recursive case, no further tweets to fetch
  if next_tweet_ids_to_fetch.empty?
    return [] of Tweet
  end

  # fetch next list
  fetched_tweets = get_tweets_by_id(next_tweet_ids_to_fetch)
  all_parent_tweets = fetched_tweets + get_all_parent_tree_tweets(fetched_tweets)

  return all_parent_tweets
end

USERNAMES = [
  "ID_AA_Carmack",
  "ziglang",
  "CrystalLanguage",
  "mitchellh",
  "paulg",
  "patrickc",
  "sama",
  "andy_matuschak",
  "danielgross",
  "thorstenball",
  "Steve_Yegge",
]

def do_stuff
  USERNAMES.each do |username|
    id = id_from_username(username)
    p "Starting to process data for #{username}"
    tweets = timeline_data(user_data_from_f[username].id)
    p "Got timeline data for #{username}"

    save_tweets_to_megalists(tweets)
    save_tweets_to_timeline_list(tweets, username)
    p "Saved timeline tweets for #{username}"

    p "Getting parent tree tweets for #{username}"
    parent_tweets : Array(Tweet) = get_all_parent_tree_tweets(tweets)
    p "Finished getting parent_tree_tweets for #{username}"
    save_tweets_to_megalists(parent_tweets)
  end
end
