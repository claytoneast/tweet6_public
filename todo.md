current dev command:

`$ crystal run builder.cr && crystal run server.cr`

# TODO
* DONE load the baby tree into final.html
* DONE use canvas test code, copy it into final.html/template.html.ecr
* DONE make sure we can render our baby tree with this server-side data
* DONE build root-tweet-only trees

* DONE client should fetch data from crystal server endpoint
* DONE endpoint must send success/fail JSON
* DONE create unique tweet chains in crystal instead of javascript
* DONE endpoint must send actual data when it has successfully written it
* DONE ignore last fetched at for now. just do the whole fuckin thing in a single chain.
* DONE Fix tweet-fetching. Should fetch Author name & Id when getting the tweets.
* DONE organize conversation chains by author and then created_at, in a dictionary. Don't do them all together.
* DONE deploy to digital ocean droplet
  * DONE might have to add/configure ngingx or caddy as a reverse proxy to the crystal app server
      * started with caddy, but ended up just binding to 0.0.0.0 (all network interfaces) with the crystal http server
* DONE show created_at on tweets
* DONE client must have left/right nav with (x/14) for usernames & for conversations
* DONE Fix deleted tweet handling. Use a single record in the JSON file for a deleted tweet's data.
* DONE only run once a day, cache the results?
* DONE fix the "sooner than" logic
* DONE add last_run_at
* DONE Undo my earlier work, make conversations a single flat array, ordered by date.
* DONE add progress in all conversations

* Fix replied_to handling. Include handling quoted and retweeted tweets.
* display media (photos/videos)
