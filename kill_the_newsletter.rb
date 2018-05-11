require "sinatra"
require "sinatra/reloader" if development?
require "fog/backblaze"
require "securerandom"
require "date"

#####################################################################################################
# CONFIGURATION

configure do
  NAME = ENV.fetch "NAME", "Kill the Newsletter!"
  DOMAIN = ENV.fetch "DOMAIN", "www.kill-the-newsletter.com"
  EMAIL_DOMAIN = ENV.fetch "EMAIL_DOMAIN", "kill-the-newsletter.com"
  URN = ENV.fetch "URN", "kill-the-newsletter"
  ADMINISTRATOR_EMAIL = ENV.fetch "ADMINISTRATOR_EMAIL", "kill-the-newsletter@leafac.com"

  STORAGE = Fog::Storage.new(
    provider: "backblaze",
    b2_account_id: ENV.fetch("B2_ACCOUNT_ID"),
    b2_account_token: ENV.fetch("B2_ACCOUNT_TOKEN"),
    b2_bucket_name: ENV.fetch("B2_BUCKET"),
  )

  BUCKET = ENV.fetch "B2_BUCKET"

  FEED_MAXIMUM_SIZE = 1_900_000
  NAME_MAXIMUM_SIZE = 1_000
end

#####################################################################################################
# ROUTE HANDLERS

get "/" do
  erb :index
end

post "/" do
  name = params["name"]
  token = fresh_token
  locals = { token: token, name: name }
  halt erb(:index, locals: { error_message: "Please provide the newsletter name." }) if name.blank?
  halt erb(:index, locals: { error_message: "Newsletter name is too long." }) if name.length > NAME_MAXIMUM_SIZE
  feed = erb :feed, layout: false, locals: locals do
    erb :entry, locals: {
      token: fresh_token,
      title: "“#{escape name}” inbox created",
      author: NAME,
      created_at: now,
      html: true,
      content: erb(:instructions, locals: locals),
    }
  end
  begin
    put_feed token, feed
    logger.info "Inbox created: #{locals}"
    erb :success, locals: locals
  rescue => error
    logger.error "Error creating inbox: #{locals}"
    logger.error error
    erb :error, locals: locals
  end
end

post "/email" do
  begin
    logger.error params
    to = params.fetch("to")
    raise Fog::Errors::NotFound if to !~ /@#{EMAIL_DOMAIN}\z/
    token = to[0...-("@#{EMAIL_DOMAIN}".length)]
    feed = get_feed token
    entry = erb :entry, layout: false, locals: {
      token: fresh_token,
      title: params.fetch("subject"),
      author: params.fetch("from"),
      created_at: now,
      html: ! params["html"].blank?,
      content: params["html"].blank? ? params.fetch("text") : params.fetch("html"),
    }
    updated_feed = feed.sub /<updated>.*?<\/updated>/, entry
    if updated_feed.bytesize > FEED_MAXIMUM_SIZE
      updated_feed = updated_feed.byteslice 0, FEED_MAXIMUM_SIZE
      updated_feed = updated_feed[/.*<\/entry>/m] || updated_feed[/.*?<\/updated>/m]
      updated_feed += "\n</feed>"
    end
    put_feed token, updated_feed
    logger.info "Received email from “#{params.fetch("from")}” to “#{to}”"
  rescue Fog::Errors::NotFound
    logger.info "Discarded email from “#{params.fetch("from")}” to “#{to}”"
  end
  200
end

get "/feeds/:token.xml" do |token|
  begin
    get_feed(token).tap { content_type "text/xml" }
  rescue Fog::Errors::NotFound
    404
  end
end

not_found do
  erb :not_found
end

#####################################################################################################
# HELPERS

helpers do
  def file token
    "#{token}.xml"
  end

  def email token
    "#{token}@#{EMAIL_DOMAIN}"
  end

  def feed token
    "https://#{DOMAIN}/feeds/#{token}.xml"
  end

  def id token
    "urn:#{URN}:#{token}"
  end

  def fresh_token
    SecureRandom.urlsafe_base64(30).tr("-_", "")[0...20].downcase
  end

  def now
    DateTime.now.rfc3339
  end

  def get_feed token
    STORAGE.get_object(BUCKET, file(token)).body
  end

  def put_feed token, feed
    STORAGE.put_object BUCKET, file(token), feed
  end

  # https://github.com/rails/rails/blob/ab3ad6a9ad119825636153cd521e25c280483340/activesupport/lib/active_support/core_ext/object/blank.rb
  class String
    def blank?
      self =~ /\A[[:space:]]*\z/
    end
  end

  class NilClass
    def blank?
      true
    end
  end

  def escape text
    Rack::Utils.escape_html text
  end
end

#####################################################################################################
# TEMPLATES

__END__

@@ layout
<!DOCTYPE html>
<html>
  <head>
    <title><%= NAME %></title>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="description" content="Convert email newsletters into Atom feeds.">
    <link rel="stylesheet" href="/stylesheets/styles.css">
    <link rel="icon" href="/favicon.ico" type="image/x-icon">
  </head>
  <body>
    <header>
      <h1><a href="/"><%= NAME %></a></h1>
      <p><%= File.read "public/images/envelope-to-feed.svg" %></p>
      <h2>Convert email newsletters into Atom feeds</h2>
    </header>
    <main>
      <%= yield %>
    </main>
    <footer>
      <p><%= NAME %> is <a href="https://github.com/leafac/kill-the-newsletter">free software</a> by <a href="https://www.leafac.com">Leandro Facchinetti</a></p>
    </footer>
  </body>
</html>

@@ index
<% if defined? error_message %>
  <p class="error"><%= error_message %></p>
<% end %>
<form method="POST" action="/">
  <p><input type="text" name="name" placeholder="Newsletter name…" autofocus></p>
  <p><input type="submit" value="Create Inbox"></p>
</form>

@@ instructions
<p>Sign up for the newsletter with<br><a href="mailto:<%= email token %>" target="_blank"><%= email token %></a></p>
<p>Subscribe to the Atom feed at<br><a href="<%= feed token %>" target="_blank"><%= feed token %></a></p>
<p><em>Don’t share these addresses!</em><br>They contain a security token<br>that other people could use to send you spam<br>and unsubscribe you from your newsletters.</p>
<p><em>Enjoy your readings!</em></p>

@@ success
<p>“<%= escape name %>” inbox created</p>
<%= erb :instructions, locals: { token: token } %>
<p><a href="/" class="button">Create Another Inbox</a></p>

@@ error
<p class="error">Error creating “<%= escape name %>” inbox!<br>Please contact the <a href="mailto:<%= ADMINISTRATOR_EMAIL%>?subject=[<%= NAME %> @ <%= DOMAIN %>] Error creating “<%= escape name %>” inbox with token “<%= token %>”">system administrator</a><br>with token “<%= token %>”.</p>

@@ not_found
<p class="error">404 Not Found</p>
<p><a href="/" class="button">Create an Inbox</a></p>

@@ feed
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
<link rel="self" type="application/atom+xml" href="<%= feed token %>"/>
<link rel="alternate" type="text/html" href="https://<%= DOMAIN %>/"/>
<title><%= escape name %></title>
<subtitle><%= NAME %> inbox “<%= email token %>”.</subtitle>
<id><%= id token %></id>
<%= yield %>
</feed>

@@ entry
<updated><%= created_at %></updated>
<entry>
  <id><%= id token %></id>
  <title><%= escape title %></title>
  <author><name><%= escape author %></name></author>
  <updated><%= created_at %></updated>
  <content<%= html ? " type=\"html\"" : "" %>><%= escape content %></content>
</entry>