require "json"
require "http/server"
require "ecr"
require "./tweet6"

embedded_html_str = {{ read_file("./out.html") }}

server = HTTP::Server.new do |context|
  path = context.request.path
  p! path

  if path == "/"
    context.response.content_type = "text/html; charset=UTF-8"
    context.response.print(embedded_html_str)
  elsif path == "/data"
    data_handler(context)
    next
  else
    context.response.content_type = "text/plain"
    context.response.print "Hello world! The time is #{Time.local}"
  end
end

address = server.bind_tcp "0.0.0.0", 8080
puts "Listening on http://#{address}"
server.listen

struct ClientResponse
  include JSON::Serializable
  property data : ClientResponseData?

  def initialize(@data : ClientResponseData?); end
end

struct ClientResponseData
  include JSON::Serializable

  property allTweets : Hash(String, ClientTweet)
  property conversationChains : Array(Array(String))
  property totalConversationsCount : Int32
  property lastRunAt : String?

  def initialize(
    @allTweets : Hash(String, ClientTweet),
    @conversationChains : Array(Array(String)),
    @totalConversationsCount : Int32,
    @lastRunAt : String?
  )
  end
end

struct ClientTweet
  include JSON::Serializable

  property text : String
  property authorName : String
  property createdAt : String
  property parentRelationship : String?
  property photos : Array(String)?

  def initialize(
    @text : String,
    @authorName : String,
    @createdAt : String,
    @parentRelationship : String?,
    @photos : Array(String)?,
  )
  end
end

struct ReferencedTweet
  include JSON::Serializable
  property type : String
  property id : String
end

LA_TIME = Time::Location.load("America/Los_Angeles")

def data_handler(context)
  should_fetch_new_from_api = true
  now = Time.utc.in(LA_TIME).to_s("%Y-%m-%d")
  last_run_at : String

  if File.exists?("./last_run_at")
    last_run_at = File.read("./last_run_at")
    should_fetch_new_from_api = false if last_run_at == now
  else
    last_run_at = now
  end

  if should_fetch_new_from_api
    do_stuff()
    build_tweet_adjacency_lists()
    build_conversation_lists()
    File.write("./last_run_at", now)
  end

  resp_data = hydrate_response_from_convo_lists()
  resp_data.lastRunAt = last_run_at
  context.response.content_type = "application/json"
  context.response.print(ClientResponse.new(resp_data).to_pretty_json)
end

struct AuthorData
  include JSON::Serializable
  property name : String
  property username : String
  property id : String
end

struct AuthorDataResp
  include JSON::Serializable
  @[JSON::Field(key: "data")]
  property users : Array(AuthorData)
end

def hydrate_response_from_convo_lists : ClientResponseData
  conversation_lists = Array(Array(String)).from_json(File.read("./conversation_lists.json"))
  unique_tweet_ids = conversation_lists.flatten.uniq
  total_conversations_count = conversation_lists.size
  all_tweet_data = Hash(String, Tweet).from_json(File.read("./megalist.json"))
  client_tweet_data = Hash(String, ClientTweet).new

  unique_tweet_ids.each do |tweet_id|
    # the hash key might be missing because of a deleted tweet. If so, then we
    # need to make a tweet with this data, and call it deleted tweet.
    tweet_data = if all_tweet_data.has_key?(tweet_id)
      all_tweet_data[tweet_id]
    else
      Tweet.new(
        "deleted_id",
        "This tweet is missing, was probably deleted",
        "1970-01-01T00:00:00.000Z",
        "fake_author_id",
        [] of ReferencedTweet,
        "Deleted_name",
        "Deleted_username",
        nil,
        nil,
      )
    end

    pst_created_at = Time.parse(
      tweet_data.created_at,
      "%Y-%m-%dT%H:%M:%S.000Z",
      Time::Location::UTC
    ).in(Time::Location.load("America/Los_Angeles"))
      .to_s("%Y-%m-%d %H:%M:%S")

    # If there is a parent relationship, list what it is. Most will be replies,
    # so ignore replies. if its not a reply, it can be a quote. then our client
    # will figure out what to do with that piece of things.
    ref_tweets = tweet_data.referenced_tweets
    parentRelationship = if ref_tweets && !ref_tweets.empty?
      ref_tweets.first.type
    end
    p! parentRelationship

    media_data = tweet_data.medias
    photos = [] of String
    if !media_data.nil?
      media_data.each { |x|
        photo_url = x.url
        if photo_url
          photos << photo_url
        end
      }
    end

    client_tweet_data[tweet_id] = ClientTweet.new(
      tweet_data.text,
      "#{tweet_data.name} (#{tweet_data.username})",
      pst_created_at,
      parentRelationship,
      photos
    )
  end

  return ClientResponseData.new(client_tweet_data, conversation_lists, total_conversations_count, "")
end

class TweetAdjList
  include JSON::Serializable

  property id : String
  property children_ids : Set(String)
  property text : String

  def initialize(id, children_ids, text)
    @id = id
    @children_ids = children_ids
    @text = text
  end
end

def build_conversation_lists
  adj_lists = Array(TweetAdjList).from_json(File.read("./trees.json"))
  nodes_by_id = adj_lists.index_by { |adj_list| adj_list.id }
  all_paths : Array(Array(String)) = [] of Array(String)
  working_path = [] of String

  # get_path_for_node_id mutates all_paths so that it will contain every single
  # individual conversation path.
  get_path_for_node_id("root", working_path, all_paths, nodes_by_id)
  all_tweet_data = Hash(String, Tweet).from_json(File.read("./megalist.json"))

  paths_without_root_and_username = [] of Array(String)
  all_paths.each do |path|
    path_without_root_and_username_nodes = path[2..(path.size - 1)]
    # if a username node has no children (no recent activity), its path here
    # will be an empty array, which causes runtime issues later, so we skip
    # them.
    if path_without_root_and_username_nodes.size > 0
      paths_without_root_and_username << path_without_root_and_username_nodes
    end
  end

  sorted_paths = paths_without_root_and_username.sort { |a, b|
    a_created_at = Time.parse(
      all_tweet_data[a.last].created_at,
      "%Y-%m-%dT%H:%M:%S.000Z",
      Time::Location.local
    )
    b_created_at = Time.parse(
      all_tweet_data[b.last].created_at,
      "%Y-%m-%dT%H:%M:%S.000Z",
      Time::Location.local
    )

    # order by created_at desc
    b_created_at <=> a_created_at
  }

  File.write("./conversation_lists.json", sorted_paths.to_pretty_json)
end

def get_path_for_node_id(node_id : String, working_path, all_paths, nodes_by_id)
  working_path.push(node_id)

  node = nodes_by_id[node_id]
  if node.children_ids.empty?
    all_paths.push(working_path.dup)
    working_path.pop
  else
    node.children_ids.each do |child_id|
      get_path_for_node_id(child_id, working_path, all_paths, nodes_by_id)
    end
    working_path.pop
  end
end

# this function builds the tweets adjacency lists for our user timelines, aka
# the tweet data for all of our tweets. It writes a "trees.json" file as its
# artifact. This is used by the canvas UI client for prototyping & exploration.
# this artifact is also consumed by another function (build_conversation_lists)
# to create the conversation id lists for the "true client".
def build_tweet_adjacency_lists
  parentNode = TweetAdjList.new("root", Set(typeof("str")).new, "root")
  node_map = {} of String => TweetAdjList
  node_map["root"] = parentNode

  user_data = user_data_from_f()
  megalist_tweet_data = get_megalist_data

  USERNAMES.each do |username|
    # set up username nodes under the root node for the whole tree
    username_node_id = "username_node_#{username}"
    usernameNode = TweetAdjList.new(username_node_id, Set(typeof("str")).new, "text_for_#{username}")
    node_map[username_node_id] = usernameNode
    parentNode.children_ids << username_node_id

    user_timeline_ids = user_data[username].timeline
    user_timeline_ids.each do |tweet_id|
      tweet_data = megalist_tweet_data[tweet_id]

      # Sometimes, we've already reconstructed the tree for say, the second
      # tweet in a timeline, based on the first tweet in the timeline. So the
      # node already exists in the node map. In that case, we (obviously) don't
      # want to overwrite it with a blank node.
      if !node_map.has_key?(tweet_id)
        # create node for this individual tweet
        adj_list = TweetAdjList.new(tweet_id, Set(typeof("str")).new, tweet_data.text)
        node_map[tweet_id] = adj_list
      end

      ref_tweets = tweet_data.referenced_tweets

      # base case: no parent tweet. attach it to the username tweet.
      if !ref_tweets || ref_tweets.empty?
        # attach this to the username tweet
        usernameNode.children_ids << tweet_id
      else
        # Otherwise, attach this tweet to its parent. attach_node_to_parent will
        # recursively attach upwards to parents until it meets the username
        # tweet.
        # TODO: Make this work for retweeted && quoted
        # if we quote. Then. We need to. do what exactly.
        # each node should have a piece of info for what its relationship to its parent is.
        # "reply", "quote", "retweet"

        # a reply is a straightforward child. A quote .... is different. how
        # should a quote display? what is a quote...
        # a quote is a conversation that is highlighted by someone else.
        # how does it display?

        # if the relationship between a tweet and its parent is quote, then everything above the parent
        # should be _under_ the child, indented to make it clear that it is a quote-tweet.

        # what if a parent tweet is quote-tweeting? holy shit unacceptable. i'd
        # have a mega-chain. out of control. maybe we set a flag. We're within a
        # quote tweet. then if we encounter another one, we return out of there.

        # so every conversation_list member must also have a "parent_relationship" attr.
        parent_relationship_type = ref_tweets.first.type
        if parent_relationship_type == "replied_to" || parent_relationship_type == "quoted"
          attach_node_to_parent(ref_tweets.first.id, tweet_id, megalist_tweet_data, node_map, usernameNode)
        end
      end
    end
  end

  File.write("trees.json", node_map.values.to_pretty_json)
end

# This function takes a child tweet id and parent tweet id, and tries to find
# the parent id on the main tree, and attach the child to it (by putting the
# child id into the children_ids of the parent node). If it does not find the
# parent id in the main tree, it builds the parent node, attaches the child,
# then recursively calls itself with the parent id of the parent node. Imagine a
# stranded child tweet from the timeline: it builds the parent chain until it
# attachs to the main tree, whether that is on some conversation, or at the root
# username node.
def attach_node_to_parent(parent_tweet_id, child_tweet_id, megalist_tweet_data, node_map, usernameNode)
  # if we don't have the tweet at all, we assumed it was deleted, and we attach
  # it to an TweetAdjList parent w/ deleted notification text, and then attach
  # that directly under the username node. Since we can get the conversation_id
  # of these tweets (even if deleted), in the future we could attach it under
  # the root member of that conversation, but that's for the future.
  if !megalist_tweet_data.has_key?(parent_tweet_id)
    parent_adj_list = TweetAdjList.new(parent_tweet_id, Set(typeof("str")).new, "This tweet was deleted :(")
    parent_adj_list.children_ids << child_tweet_id
    node_map[parent_tweet_id] = parent_adj_list
    usernameNode.children_ids << parent_tweet_id
    return
  end

  parent_tweet = megalist_tweet_data[parent_tweet_id]

  # if node_map has the key, that means that we've already encountered this
  # parent tweet, and that its "branch" is built & attached to the root, so we
  # simply attach our current tweet "under" it.
  if node_map.has_key?(parent_tweet_id)
    parent_adj_list = node_map[parent_tweet_id]
    next_children_ids = parent_adj_list.children_ids
    next_children_ids << child_tweet_id
    parent_adj_list.children_ids = next_children_ids
    node_map[parent_tweet_id] = parent_adj_list
  else
    # if the node_map doesn't have the key, then we've never seen the parent
    # before. We need to build it, attach the child, then add it to the
    # node_map.
    parent_adj_list = TweetAdjList.new(parent_tweet_id, Set(typeof("str")).new, parent_tweet.text)
    parent_adj_list.children_ids << child_tweet_id
    node_map[parent_tweet_id] = parent_adj_list
    ref_tweets = parent_tweet.referenced_tweets

    # once added, we check if the parent has a parent. If so, we recurse our
    # attach_node_to_parent. If it doesn't have a parent, we attach it to its
    # username node since it is a "root-level" node for that specific user.

    # TODO:
    # parent_relationship_type = ref_tweets.first.type
    # if parent_relationship_type == "replied_to" || parent_relationship_type == "quoted"

    if ref_tweets && ref_tweets.size > 0
      if ref_tweets.first.type == "replied_to"
        attach_node_to_parent(ref_tweets.first.id, parent_tweet_id, megalist_tweet_data, node_map, usernameNode)
      end
    else
      usernameNode.children_ids << parent_tweet_id
    end
  end
end
