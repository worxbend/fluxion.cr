module Fluxion
  # Strips the parts of a URL that must never be persisted or displayed.
  #
  # Query strings carry signed-request parameters and tokens; user-info carries
  # credentials outright. Both are legitimate on the wire, so they stay on the
  # download request — but plans, events, failure messages, state files, and
  # phase fingerprints all get this form instead.
  module PublicUrl
    extend self

    def from(url : String) : String
      truncated = truncate_at_query(url)
      strip_user_info(truncated)
    end

    def from(url : URI) : String
      from(url.to_s)
    end

    private def truncate_at_query(url : String) : String
      question = url.index('?')
      hash = url.index('#')
      cut = if question && hash
              Math.min(question, hash)
            else
              question || hash
            end
      cut ? url[0, cut] : url
    end

    # Removes everything between the scheme separator and the last `@` that
    # still falls inside the authority. Using the last `@` matters: a password
    # may itself contain one.
    private def strip_user_info(url : String) : String
      separator = url.index("://")
      return url unless separator

      authority_start = separator + 3
      authority_end = url.index('/', authority_start) || url.size
      at = url.rindex('@', authority_end - 1)
      return url unless at && at >= authority_start

      url[0, authority_start] + url[(at + 1)..]
    end
  end
end
