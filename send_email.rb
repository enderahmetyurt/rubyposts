#!/usr/bin/env ruby
# frozen_string_literal: true

# Sends the daily Ruby digest email via Resend API.
# Usage:
#   RESEND_API_KEY=... TO_EMAIL=... ruby send_email.rb
#   RESEND_API_KEY=... TO_EMAIL=... ruby send_email.rb --lang=tr   (default: both)
#   RESEND_API_KEY=... TO_EMAIL=... ruby send_email.rb --dry-run   (print HTML, don't send)

require "json"
require "net/http"
require "uri"
require "time"
require "erb"

DATA_FILE = File.join(__dir__, "data", "items.json")

RESEND_API_KEY = ENV.fetch("RESEND_API_KEY") { abort "RESEND_API_KEY is not set." }
TO_EMAIL       = ENV.fetch("TO_EMAIL")       { abort "TO_EMAIL is not set." }
FROM_EMAIL     = ENV.fetch("FROM_EMAIL", "Ruby Digest <digest@yourdomain.com>")

LANG    = (ARGV.grep(/--lang=/).first&.split("=")&.last || "both")  # tr, en, both
DRY_RUN = ARGV.include?("--dry-run")

# Only items from the last 24 hours (or 7 days if weekly mode)
HOURS_BACK = ENV.fetch("HOURS_BACK", "24").to_i

def send_via_resend(to:, from:, subject:, html:)
  uri = URI("https://api.resend.com/emails")

  body = { from: from, to: [to], subject: subject, html: html }.to_json

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = true
  http.open_timeout = 10
  http.read_timeout = 15

  request = Net::HTTP::Post.new(uri)
  request["Content-Type"]  = "application/json"
  request["Authorization"] = "Bearer #{RESEND_API_KEY}"
  request.body = body

  response = http.request(request)
  raise "Resend error: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
end

def build_html(items, lang)
  date_str = Time.now.strftime("%B %d, %Y")

  summary_key = lang == "tr" ? "summary_tr" : "summary_en"
  title_str   = lang == "tr" ? "Ruby Posts - #{date_str}" : "Ruby Posts - #{date_str}"
  header_note = lang == "tr" ? "Son 24 saatin Ruby haberleri" : "Ruby news from the last 24 hours"

  # Sort by score descending
  sorted = items.sort_by { |i| -(i["score"] || 0) }

  ERB.new(HTML_TEMPLATE).result(binding)
end

HTML_TEMPLATE = <<~HTML
  <!DOCTYPE html>
  <html lang="<%= lang == "tr" ? "tr" : "en" %>">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title><%= title_str %></title>
    <style>
      body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; max-width: 640px; margin: 0 auto; padding: 24px 16px; color: #1a1a1a; background: #fff; }
      h1 { font-size: 22px; font-weight: 700; margin-bottom: 4px; color: #cc0000; }
      .meta { font-size: 13px; color: #666; margin-bottom: 32px; }
      .item { margin-bottom: 28px; border-left: 3px solid #eee; padding-left: 14px; }
      .item:hover { border-left-color: #cc0000; }
      .item-title { font-size: 16px; font-weight: 600; margin: 0 0 4px; }
      .item-title a { color: #1a1a1a; text-decoration: none; }
      .item-title a:hover { color: #cc0000; }
      .item-meta { font-size: 12px; color: #888; margin-bottom: 6px; }
      .item-summary { font-size: 14px; color: #444; line-height: 1.6; margin: 0; }
      .score-high { border-left-color: #cc0000; }
      .score-mid  { border-left-color: #f0a000; }
      hr { border: none; border-top: 1px solid #eee; margin: 32px 0; }
      .footer { font-size: 12px; color: #999; text-align: center; }
    </style>
  </head>
  <body>
    <h1>💎 Ruby Digest</h1>
    <p class="meta"><%= header_note %> &bull; <%= date_str %></p>

    <% sorted.each do |item| %>
      <%
        score = item["score"].to_i
        css_class = score >= 8 ? "item score-high" : (score >= 6 ? "item score-mid" : "item")
        summary = item[summary_key].to_s
        next if summary.empty?
      %>
      <div class="<%= css_class %>">
        <h2 class="item-title">
          <a href="<%= item["url"] %>" target="_blank"><%= item["title"] %></a>
        </h2>
        <div class="item-meta">
          <%= item["source"] %> &bull; <%= item["published"][0, 10] %>
        </div>
        <p class="item-summary"><%= summary %></p>
      </div>
    <% end %>

    <hr>
    <p class="footer">
      Ruby Digest &bull; Powered by <a href="https://planetruby.org">Planet Ruby</a> feeds
    </p>
  </body>
  </html>
HTML

# --- Main ---

abort "No data file at #{DATA_FILE}. Run fetch.rb and ai_summarize.rb first." unless File.exist?(DATA_FILE)

items = JSON.parse(File.read(DATA_FILE))

# Filter: only relevant, only recent, must have summaries
cutoff = (Time.now.utc - HOURS_BACK * 3600).iso8601
recent_items = items.select do |item|
  item["relevant"] != false &&
    item["ai_filtered"] &&
    item["published"] >= cutoff &&
    (!item["summary_en"].to_s.empty? || !item["summary_tr"].to_s.empty?)
end

if recent_items.empty?
  puts "No new items in the last #{HOURS_BACK} hours. Skipping email."
  exit 0
end

puts "#{recent_items.length} items to send"
date_str = Time.now.strftime("%B %d, %Y")

langs_to_send = case LANG
                when "tr"   then ["tr"]
                when "en"   then ["en"]
                else             ["tr", "en"]
                end

langs_to_send.each do |lang|
  html    = build_html(recent_items, lang)
  subject = lang == "tr" ? "Ruby Digest - #{date_str}" : "Ruby Digest - #{date_str}"

  if DRY_RUN
    puts "\n--- DRY RUN (#{lang}) ---"
    puts html
    next
  end

  result = send_via_resend(to: TO_EMAIL, from: FROM_EMAIL, subject: subject, html: html)
  puts "Sent (#{lang}): #{result["id"]}"
end

puts "Done."
