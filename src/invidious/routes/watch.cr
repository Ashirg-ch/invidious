{% skip_file if flag?(:api_only) %}

module Invidious::Routes::Watch
  def self.handle(env)
    locale = env.get("preferences").as(Preferences).locale
    region = env.params.query["region"]?

    if env.params.query.to_s.includes?("%20") || env.params.query.to_s.includes?("+")
      url = "/watch?" + env.params.query.to_s.gsub("%20", "").delete("+")
      return env.redirect url
    end

    if env.params.query["v"]?
      id = env.params.query["v"]

      if env.params.query["v"].empty?
        return error_template(400, "Invalid parameters.")
      end

      if id.size > 11
        url = "/watch?v=#{id[0, 11]}"
        env.params.query.delete_all("v")
        if env.params.query.size > 0
          url += "&#{env.params.query}"
        end

        return env.redirect url
      end
    else
      return env.redirect "/"
    end

    embed_link = "/embed/#{id}"
    if env.params.query.size > 1
      embed_params = HTTP::Params.parse(env.params.query.to_s)
      embed_params.delete_all("v")
      embed_link += "?"
      embed_link += embed_params.to_s
    end

    plid = env.params.query["list"]?.try &.gsub(/[^a-zA-Z0-9_-]/, "")
    continuation = process_continuation(env.params.query, plid, id)

    nojs = env.params.query["nojs"]?

    nojs ||= "0"
    nojs = nojs == "1"

    preferences = env.get("preferences").as(Preferences)

    user = env.get?("user").try &.as(User)
    if user
      subscriptions = user.subscriptions
      watched = user.watched
      notifications = user.notifications
    end
    subscriptions ||= [] of String

    params = process_video_params(env.params.query, preferences)
    env.params.query.delete_all("listen")

    begin
      video = get_video(id, region: params.region)
    rescue ex : NotFoundException
      LOGGER.error("get_video not found: #{id} : #{ex.message}")
      return error_template(404, ex)
    rescue ex
      LOGGER.error("get_video: #{id} : #{ex.message}")
      return error_template(500, ex)
    end

    if preferences.annotations_subscribed &&
       subscriptions.includes?(video.ucid) &&
       (env.params.query["iv_load_policy"]? || "1") == "1"
      params.annotations = true
    end
    env.params.query.delete_all("iv_load_policy")

    if watched && preferences.watch_history && !watched.includes? id
      Invidious::Database::Users.mark_watched(user.as(User), id)
    end

    if CONFIG.enable_user_notifications && notifications && notifications.includes? id
      Invidious::Database::Users.remove_notification(user.as(User), id)
      env.get("user").as(User).notifications.delete(id)
      notifications.delete(id)
    end

    if nojs
      if preferences
        source = preferences.comments[0]
        if source.empty?
          source = preferences.comments[1]
        end

        if source == "youtube"
          begin
            comment_html = JSON.parse(fetch_youtube_comments(id, nil, "html", locale, preferences.thin_mode, region))["contentHtml"]
          rescue ex
            if preferences.comments[1] == "reddit"
              comments, reddit_thread = fetch_reddit_comments(id)
              comment_html = template_reddit_comments(comments, locale)

              comment_html = fill_links(comment_html, "https", "www.reddit.com")
              comment_html = replace_links(comment_html)
            end
          end
        elsif source == "reddit"
          begin
            comments, reddit_thread = fetch_reddit_comments(id)
            comment_html = template_reddit_comments(comments, locale)

            comment_html = fill_links(comment_html, "https", "www.reddit.com")
            comment_html = replace_links(comment_html)
          rescue ex
            if preferences.comments[1] == "youtube"
              comment_html = JSON.parse(fetch_youtube_comments(id, nil, "html", locale, preferences.thin_mode, region))["contentHtml"]
            end
          end
        end
      else
        comment_html = JSON.parse(fetch_youtube_comments(id, nil, "html", locale, preferences.thin_mode, region))["contentHtml"]
      end

      comment_html ||= ""
    end

    fmt_stream = video.fmt_stream
    adaptive_fmts = video.adaptive_fmts

    if params.local
      fmt_stream.each { |fmt| fmt["url"] = JSON::Any.new(URI.parse(fmt["url"].as_s).request_target) }
      adaptive_fmts.each { |fmt| fmt["url"] = JSON::Any.new(URI.parse(fmt["url"].as_s).request_target) }
    end

    video_streams = video.video_streams
    audio_streams = video.audio_streams

    # Older videos may not have audio sources available.
    # We redirect here so they're not unplayable
    if audio_streams.empty? && !video.live_now
      if params.quality == "dash"
        env.params.query.delete_all("quality")
        env.params.query["quality"] = "medium"
        return env.redirect "/watch?#{env.params.query}"
      elsif params.listen
        env.params.query.delete_all("listen")
        env.params.query["listen"] = "0"
        return env.redirect "/watch?#{env.params.query}"
      end
    end

    captions = video.captions

    preferred_captions = captions.select { |caption|
      params.preferred_captions.includes?(caption.name) ||
        params.preferred_captions.includes?(caption.language_code.split("-")[0])
    }
    preferred_captions.sort_by! { |caption|
      (params.preferred_captions.index(caption.name) ||
        params.preferred_captions.index(caption.language_code.split("-")[0])).not_nil!
    }
    captions = captions - preferred_captions

    aspect_ratio = "16:9"

    thumbnail = "https://proxy.invidio.xamh.de/vi/#{video.id}/maxresdefault.jpg?host=i.ytimg.com"

    if params.raw
      if params.listen
        url = audio_streams[0]["url"].as_s

        if params.quality.ends_with? "k"
          audio_streams.each do |fmt|
            if fmt["bitrate"].as_i == params.quality.rchop("k").to_i
              url = fmt["url"].as_s
            end
          end
        end
      else
        url = fmt_stream[0]["url"].as_s

        fmt_stream.each do |fmt|
          if fmt["quality"].as_s == params.quality
            url = fmt["url"].as_s
          end
        end
      end

      return env.redirect url
    end

    # Structure used for the download widget
    video_assets = Invidious::Frontend::WatchPage::VideoAssets.new(
      full_videos: fmt_stream,
      video_streams: video_streams,
      audio_streams: audio_streams,
      captions: video.captions
    )

    templated "watch"
  end

  def self.redirect(env)
    url = "/watch?v=#{env.params.url["id"]}"
    if env.params.query.size > 0
      url += "&#{env.params.query}"
    end

    return env.redirect url
  end

  def self.mark_watched(env)
    locale = env.get("preferences").as(Preferences).locale

    user = env.get? "user"
    sid = env.get? "sid"
    referer = get_referer(env, "/feed/subscriptions")

    redirect = env.params.query["redirect"]?
    redirect ||= "true"
    redirect = redirect == "true"

    if !user
      if redirect
        return env.redirect referer
      else
        return error_json(403, "No such user")
      end
    end

    user = user.as(User)
    sid = sid.as(String)
    token = env.params.body["csrf_token"]?

    id = env.params.query["id"]?
    if !id
      env.response.status_code = 400
      return
    end

    begin
      validate_request(token, sid, env.request, HMAC_KEY, locale)
    rescue ex
      if redirect
        return error_template(400, ex)
      else
        return error_json(400, ex)
      end
    end

    if env.params.query["action_mark_watched"]?
      action = "action_mark_watched"
    elsif env.params.query["action_mark_unwatched"]?
      action = "action_mark_unwatched"
    else
      return env.redirect referer
    end

    case action
    when "action_mark_watched"
      if !user.watched.includes? id
        Invidious::Database::Users.mark_watched(user, id)
      end
    when "action_mark_unwatched"
      Invidious::Database::Users.mark_unwatched(user, id)
    else
      return error_json(400, "Unsupported action #{action}")
    end

    if redirect
      env.redirect referer
    else
      env.response.content_type = "application/json"
      "{}"
    end
  end

  def self.clip(env)
    clip_id = env.params.url["clip"]?

    return error_template(400, "A clip ID is required") if !clip_id

    response = YoutubeAPI.resolve_url("https://www.youtube.com/clip/#{clip_id}")
    return error_template(400, "Invalid clip ID") if response["error"]?

    if video_id = response.dig?("endpoint", "watchEndpoint", "videoId")
      return env.redirect "/watch?v=#{video_id}&#{env.params.query}"
    else
      return error_template(404, "The requested clip doesn't exist")
    end
  end

  def self.download(env)
    return error_template(403, "Administrator has disabled this endpoint.")
  end
end
