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
  property tweets : Array(ApiTweet)

  property meta : TimelineMeta
end

struct ListTweetsResponse
  include JSON::Serializable

  @[JSON::Field(key: "data")]
  property tweets : Array(ApiTweet)
end

struct TimelineMeta
  include JSON::Serializable

  property next_token : String?
  property previous_token : String?
  # I think results can only be up to 100 tweets at a time, hence Int8
  property result_count : Int8?
end

struct ApiTweet
  include JSON::Serializable

  property id : String

  property text : String
  property created_at : String
  property author_id : String
  property referenced_tweets : Array(ReferencedTweet)?
end

struct ReferencedTweet
  include JSON::Serializable

  property type : String
  property id : String
end

struct Tweet
  include JSON::Serializable

  property text : String
  property created_at : String
  property author_id : String
  property referenced_tweets : Array(ReferencedTweet)?

  def initialize(@text : String, @created_at : String, @author_id : String, @referenced_tweets : Array(ReferencedTweet)?)
  end
end

def get_timeline_data(user_id : String, next_token : String | Nil = nil)
  # date strings must be in https://www.rfc-editor.org/rfc/rfc3339#page-10 format
  since_str = "2022-05-20T00:00:00Z"
  timeline_url = "https://api.twitter.com/2/users/#{user_id}/tweets?"
  params = {
    "start_time"   => since_str,
    "tweet.fields" => "id,created_at,text,author_id,referenced_tweets",
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

  if response.status_code != 200
    p!(response)
    raise Exception.new(message: "failure to get timeline: #{response.status_message}")
  end

  return TimelineResponse.from_json(response.body)
end

def timeline_data(user_id) : Array(ApiTweet)
  all_data = [] of ApiTweet
  first_response_body = get_timeline_data(user_id)
  # calling first_response_body.tweets results in a runtime error if there are
  # no tweets in the response, hence early return if meta says no results
  if first_response_body.meta.result_count == 0
    return all_data
  end

  all_data = first_response_body.tweets
  next_token = first_response_body.meta.next_token

  while next_token
    next_body_res = get_timeline_data(user_id, next_token)
    if next_body_res.meta.result_count == 0
      break
    end

    next_body_data = next_body_res.tweets

    next_body_data.each do |d|
      all_data << d
    end

    next_token = next_body_res.meta.next_token
  end

  return all_data
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
  File.open(USER_DATA_PATH) do |file|
    return Hash(String, UserData).from_json(file)
  end
end

def save_tweets_to_timeline_list(tweets : Array(ApiTweet), username : String)
  all_user_data = user_data_from_f()
  if !all_user_data.has_key?(username)
    raise Exception.new(message: "Username:#{username} not found")
  end

  our_user = all_user_data[username]

  tweets.each do |tweet|
    if !our_user.timeline.includes?(tweet.id)
      our_user.timeline.push(tweet.id)
    end
  end

  all_user_data[username] = our_user
  File.write("user_data.json", all_user_data.to_pretty_json)
end

def save_tweets_to_megalists(tweets : Array(ApiTweet))
  megalist_file_data = File.open(MEGALIST_PATH)
  megalist_tweet_data = Hash(String, Tweet).from_json(megalist_file_data)

  tweets.each do |tweet|
    if !megalist_tweet_data.has_key?(tweet.id)
      # awkward, but don't know how to do this better rn. Someday™ problem.
      megalist_tweet_data[tweet.id] = Tweet.from_json(
        Hash{
          "text"              => tweet.text,
          "created_at"        => tweet.created_at,
          "author_id"         => tweet.author_id,
          "referenced_tweets" => tweet.referenced_tweets,
        }.to_json
      )
    end
  end

  File.write(MEGALIST_PATH, megalist_tweet_data.to_pretty_json)
end

def id_set_from_megalist
  megalist_file_data = File.open(MEGALIST_PATH)
  megalist_tweet_data = Hash(String, Tweet).from_json(megalist_file_data)
  return Set(String){*megalist_tweet_data.keys}
end

def get_tweets_by_id(tweet_ids : Array(String)) : Array(ApiTweet)
  # this endpoint can only accept 100 ids at a time so at some point this shit
  # is going to break but that's for Someday™.
  all_fetched_tweets = [] of ApiTweet
  tweet_ids.each_slice(100) do |id_slice|
    params = {
      "ids"          => id_slice.join(","),
      "tweet.fields" => "id,created_at,text,author_id,referenced_tweets",
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
    resStr = ListTweetsResponse.from_json(response.body)
    all_fetched_tweets += resStr.tweets
  end

  return all_fetched_tweets
end

def get_all_parent_tree_tweets(tweets)
  # TODO: Should check the megalist to see if we already have the tweets stored
  # before reaching out to twitter again.
  all_parent_tweets = [] of ApiTweet
  next_tweet_ids_to_fetch = [] of String

  tweets.each do |tweet|
    ref_tweets = tweet.referenced_tweets
    if ref_tweets
      # possibly types: retweeted, quoted, replied_to. Handle only replied_to
      # right now, rest later.
      parent_tweet = ref_tweets.select { |x| x.type == "replied_to" }
      if parent_tweet.size > 0
        next_tweet_ids_to_fetch << parent_tweet.first.id
      end

      if ref_tweets.size > 1
        p! "------------ there are more than 1 referenced tweets!!!!!!!!!!!!!"
        p! ref_tweets
      end
    end
  end

  # base recursive case, no further tweets to fetch
  if next_tweet_ids_to_fetch.empty?
    return [] of ApiTweet
  end

  # fetch next list
  fetched_tweets = get_tweets_by_id(next_tweet_ids_to_fetch)

  all_parent_tweets = fetched_tweets + get_all_parent_tree_tweets(fetched_tweets)

  return all_parent_tweets
end

USERNAMES = [
  "Jonathan_Blow",
  "cmuratori",
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
    parent_tweets : Array(ApiTweet) = get_all_parent_tree_tweets(tweets)
    p "Finished getting parent_tree_tweets for #{username}"
    p! parent_tweets
    save_tweets_to_megalists(parent_tweets)
  end

  client_tree_data = build_tweet_trees(USERNAMES)
  File.write("trees.json", client_tree_data.to_pretty_json)
end

class HtmlVars
  def initialize(@json_data : String)
  end

  ECR.def_to_s "template.html.ecr"
end

def print_tweets_to_html(intermediates_list)
  file_data = File.open(MEGALIST_PATH)
  p! intermediates_list.to_json
  html_str = HtmlVars.new(intermediates_list.to_json).to_s
  File.write("./final.html", html_str)
end

class Intermediate
  include JSON::Serializable

  property id : String
  property childrenIds : Set(String)
  property text : String

  def initialize(id, childrenIds, text)
    @id = id
    @childrenIds = childrenIds
    @text = text
  end
end

# TODO: we've built the trees for the prototyping UI. we could now build the "id
# sets" for the real UI. or we could crawl the tree on the frontend somehow?

# say we start with root node.
# we have its children in an array.
# we keep track of which current child we are at in that array with an index.
# look up that node. if it has children, we are in the first one. recurse to find children.
# so when moving sideways, check: at the last node???


def build_tweet_trees(usernames)
  parentNode = Intermediate.new("root", Set(typeof("str")).new, "root")
  node_map = {} of String => Intermediate
  node_map["root"] = parentNode

  ud = user_data_from_f()
  megalist_tweet_data = Hash(String, Tweet).from_json(File.open(MEGALIST_PATH))

  usernames.each do |username|
    username_node_id = "username_node_#{username}"
    usernameNode = Intermediate.new(username_node_id, Set(typeof("str")).new, "text_for_#{username}")
    node_map[username_node_id] = usernameNode
    parentNode.childrenIds << username_node_id

    user_timeline_ids = ud[username].timeline
    user_timeline_ids.each do |tweet_id|
      tweet_data = megalist_tweet_data[tweet_id]
      ref_tweets = tweet_data.referenced_tweets

      if tweet_id == "1527851753684668416"
        p! tweet_data
        p! ref_tweets
      end

      intermediate = Intermediate.new(tweet_id, Set(typeof("str")).new, tweet_data.text)
      node_map[tweet_id] = intermediate

      # base case: no parent tweet. attach it to the username tweet.
      if !ref_tweets || ref_tweets.empty?
        # attach this to the username tweet
        usernameNode.childrenIds << tweet_id
      else
        # TODO: Make this work for retweeted && quoted
        if ref_tweets.first.type == "replied_to"
          attach_node_to_parent(ref_tweets.first.id, tweet_id, megalist_tweet_data, node_map, usernameNode)
        end
      end
    end
  end

  return node_map.values
end

def attach_node_to_parent(parent_tweet_id, child_tweet_id, megalist_tweet_data, node_map, usernameNode)
  # if we don't have the tweet at all (if for instance, it was deleted), then we
  # attach it to an Intermediate parent w/ deleted notification text, and then
  # attach that directly under the username node. We could in the future, since
  # we have the conversation_id, attach it under the root member of that
  # conversation, but that's a future project.
  if !megalist_tweet_data.has_key?(parent_tweet_id)
    parent_intermediate = Intermediate.new(parent_tweet_id, Set(typeof("str")).new, "This tweet was deleted :(")
    parent_intermediate.childrenIds << child_tweet_id
    node_map[parent_tweet_id] = parent_intermediate
    usernameNode.childrenIds << parent_tweet_id
    return
  end

  parent_tweet = megalist_tweet_data[parent_tweet_id]

  # if node_map has the key, that means that we've already encountered this
  # parent tweet, and that its "branch" is built & attached to the root, so we
  # simply attach our current tweet "under" it.
  if node_map.has_key?(parent_tweet_id)
    parent_intermediate = node_map[parent_tweet_id]
    parent_intermediate.childrenIds << child_tweet_id
  else
    # if the node_map doesn't have the key, then we've never seen the parent
    # before. We need to build it, attach the child, then add it to the
    # node_map.
    parent_intermediate = Intermediate.new(parent_tweet_id, Set(typeof("str")).new, parent_tweet.text)
    parent_intermediate.childrenIds << child_tweet_id
    node_map[parent_tweet_id] = parent_intermediate

    # once added, we check if the parent has a parent. If so, we recurse our
    # attach_node_to_parent.
    ref_tweets = parent_tweet.referenced_tweets
    if ref_tweets && ref_tweets.size > 0
      if ref_tweets.first.type == "replied_to"
        attach_node_to_parent(ref_tweets.first.id, parent_tweet_id, megalist_tweet_data, node_map, usernameNode)
      end
    else
      usernameNode.childrenIds << parent_tweet_id
    end
  end
end

do_stuff()
