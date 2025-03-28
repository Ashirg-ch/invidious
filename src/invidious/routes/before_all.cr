module Invidious::Routes::BeforeAll
  def self.handle(env)
    preferences = Preferences.from_json("{}")

    begin
      if prefs_cookie = env.request.cookies["PREFS"]?
        preferences = Preferences.from_json(URI.decode_www_form(prefs_cookie.value))
      else
        if language_header = env.request.headers["Accept-Language"]?
          if language = ANG.language_negotiator.best(language_header, LOCALES.keys)
            preferences.locale = language.header
          end
        end
      end
    rescue
      preferences = Preferences.from_json("{}")
    end

    env.set "preferences", preferences
    env.response.headers["X-XSS-Protection"] = "1; mode=block"
    env.response.headers["X-Content-Type-Options"] = "nosniff"

    # Allow media resources to be loaded from google servers
    # TODO: check if *.youtube.com can be removed
    if CONFIG.disabled?("local") || !preferences.local
      extra_media_csp = " https://*.googlevideo.com:443 https://*.youtube.com:443 https://proxy.invidio.xamh.de:443"
    else
      extra_media_csp = " https://proxy.invidio.xamh.de:443"
    end

    # Only allow the pages at /embed/* to be embedded
    if env.request.resource.starts_with?("/embed")
      frame_ancestors = "'self' http: https:"
    else
      frame_ancestors = "'none'"
    end

    # TODO: Remove style-src's 'unsafe-inline', requires to remove all
    # inline styles (<style> [..] </style>, style=" [..] ")
    env.response.headers["Content-Security-Policy"] = {
      "default-src 'self' *.xamh.de watch.thekitty.zone",
      "script-src 'self' static.xamh.de",
      "style-src 'self' static.xamh.de 'unsafe-inline'",
      "img-src 'self' proxy.invidio.xamh.de data:",
      "font-src 'self' static.xamh.de data:",
      "connect-src 'self'  proxy.invidio.xamh.de",
      "manifest-src 'self'  *.xamh.de watch.thekitty.zone",
      "media-src 'self' *.xamh.de watch.thekitty.zone blob:" + extra_media_csp,
      "child-src 'self' blob:",
      "frame-src 'self'  *.xamh.de",
      "frame-ancestors " + frame_ancestors,
    }.join("; ")
    env.response.headers["Access-Control-Allow-Origin"] = "*"
    env.response.headers["Referrer-Policy"] = "allow-origin"
    env.response.headers["Access-Control-Allow-Credentials"] = "true"

    # Ask the chrom*-based browsers to disable FLoC
    # See: https://blog.runcloud.io/google-floc/
    env.response.headers["Permissions-Policy"] = "interest-cohort=()"

    if (Kemal.config.ssl || CONFIG.https_only) && CONFIG.hsts
      env.response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains; preload"
    end

    return if {
                "/sb/",
                "/vi/",
                "/s_p/",
                "/yts/",
                "/ggpht/",
                "/api/manifest/",
                "/videoplayback",
                "/latest_version",
                "/download",
              }.any? { |r| env.request.resource.starts_with? r }

    if env.request.cookies.has_key? "SID"
      sid = env.request.cookies["SID"].value

      if sid.starts_with? "v1:"
        raise "Cannot use token as SID"
      end

      # Invidious users only have SID
      if !env.request.cookies.has_key? "SSID"
        if email = Invidious::Database::SessionIDs.select_email(sid)
          user = Invidious::Database::Users.select!(email: email)
          csrf_token = generate_response(sid, {
            ":authorize_token",
            ":playlist_ajax",
            ":signout",
            ":subscription_ajax",
            ":token_ajax",
            ":watch_ajax",
          }, HMAC_KEY, 1.week)

          preferences = user.preferences
          env.set "preferences", preferences

          env.set "sid", sid
          env.set "csrf_token", csrf_token
          env.set "user", user
        end
      else
        headers = HTTP::Headers.new
        headers["Cookie"] = env.request.headers["Cookie"]

        begin
          user, sid = get_user(sid, headers, false)
          csrf_token = generate_response(sid, {
            ":authorize_token",
            ":playlist_ajax",
            ":signout",
            ":subscription_ajax",
            ":token_ajax",
            ":watch_ajax",
          }, HMAC_KEY, 1.week)

          preferences = user.preferences
          env.set "preferences", preferences

          env.set "sid", sid
          env.set "csrf_token", csrf_token
          env.set "user", user
        rescue ex
        end
      end
    end

    dark_mode = convert_theme(env.params.query["dark_mode"]?) || preferences.dark_mode.to_s
    thin_mode = env.params.query["thin_mode"]? || preferences.thin_mode.to_s
    thin_mode = thin_mode == "true"
    locale = env.params.query["hl"]? || preferences.locale

    preferences.dark_mode = dark_mode
    preferences.thin_mode = thin_mode
    preferences.locale = locale
    env.set "preferences", preferences

    current_page = env.request.path
    if env.request.query
      query = HTTP::Params.parse(env.request.query.not_nil!)

      if query["referer"]?
        query["referer"] = get_referer(env, "/")
      end

      current_page += "?#{query}"
    end

    env.set "current_page", URI.encode_www_form(current_page)
  end
end
