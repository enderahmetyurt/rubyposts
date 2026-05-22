#!/usr/bin/env ruby
# frozen_string_literal: true

# Filters and summarizes items using Anthropic API.
# Adds Turkish (tr) and English (en) summaries to each item.
# Based on Planet Ruby's ai_filter.rb - MIT License.

require "json"
require "net/http"
require "uri"
require "time"

DATA_FILE = File.join(__dir__, "data", "items.json")

ANTHROPIC_API_KEY = ENV.fetch("ANTHROPIC_API_KEY") do
  abort "ANTHROPIC_API_KEY environment variable is not set."
end

ANTHROPIC_URL = URI("https://api.anthropic.com/v1/messages")
MODEL         = "claude-haiku-4-5-20251001"  # Fast and cheap, good enough for summaries

SYSTEM_PROMPT = <<~PROMPT
  You are a content filter and summarizer for a Ruby/Rails news digest.

  Given an item's source, title, and excerpt, you must:

  1. Decide if this item is relevant to Ruby, Rails, or their ecosystem.
     - Keep Ruby/Rails releases, tutorials, gems, tools, security advisories, community news.
     - Remove pure GitLab/GitHub product announcements that are not Ruby-specific.
     - Remove generic tech articles that just happen to mention Ruby once.

  2. Write a short English summary (2-3 sentences max, plain language).

  3. Write a short Turkish summary (2-3 sentences max, plain language).
     - Write in natural Turkish, not a word-for-word translation.
     - Use "Rails" not "Ruby on Rails".

  4. Score the item 1-10 based on usefulness:
     - 9-10: Ruby/Rails releases, security fixes
     - 7-8: New gems, important ecosystem news
     - 5-6: Tutorials, tips, community posts
     - 1-4: Generic or low-value content

  Return ONLY a JSON object with these fields:
  - "relevant": boolean
  - "summary_en": string (English summary, empty string if not relevant)
  - "summary_tr": string (Turkish summary, empty string if not relevant)
  - "score": integer 1-10
PROMPT

def call_anthropic(source, title, excerpt)
  user_message = "Source: #{source}\nTitle: #{title}\nExcerpt: #{excerpt}"

  body = {
    model:      MODEL,
    max_tokens: 500,
    system:     SYSTEM_PROMPT,
    messages:   [{ role: "user", content: user_message }]
  }.to_json

  http = Net::HTTP.new(ANTHROPIC_URL.host, ANTHROPIC_URL.port)
  http.use_ssl      = true
  http.open_timeout = 15
  http.read_timeout = 30

  request = Net::HTTP::Post.new(ANTHROPIC_URL)
  request["Content-Type"]      = "application/json"
  request["x-api-key"]         = ANTHROPIC_API_KEY
  request["anthropic-version"] = "2023-06-01"
  request.body = body

  response = http.request(request)
  raise "Anthropic API error: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

  data    = JSON.parse(response.body)
  content = data.dig("content", 0, "text")

  # Strip markdown code fences if present
  clean = content.gsub(/```json\s*/, "").gsub(/```\s*/, "").strip
  JSON.parse(clean)
end

# --- Main ---

abort "No data file at #{DATA_FILE}. Run fetch.rb first." unless File.exist?(DATA_FILE)

items = JSON.parse(File.read(DATA_FILE))
FORCE = ARGV.include?("--force")

if FORCE
  puts "Force mode: reprocessing all items"
  items.each { |i| i.delete("ai_filtered"); i.delete("summary_en"); i.delete("summary_tr") }
end

to_process = items.reject { |i| i["ai_filtered"] }
puts "#{items.length} items total, #{to_process.length} to process"

mutex     = Mutex.new
processed = 0

queue = Queue.new
to_process.each { |item| queue << item }
3.times { queue << nil }  # 3 threads to avoid rate limits

threads = 3.times.map do
  Thread.new do
    while (item = queue.pop)
      num    = mutex.synchronize { processed += 1 }
      prefix = "[#{num}/#{to_process.length}] #{item["source"]}: #{item["title"].to_s[0, 50]}..."

      begin
        result = call_anthropic(item["source"], item["title"], item["excerpt"])

        mutex.synchronize do
          if result["relevant"]
            item["summary_en"]  = result["summary_en"].to_s
            item["summary_tr"]  = result["summary_tr"].to_s
            item["score"]       = result["score"].to_i
            item["ai_filtered"] = true
            puts "#{prefix} KEEP (#{result["score"]}/10)"
          else
            item["ai_filtered"] = true
            item["relevant"]    = false
            puts "#{prefix} REMOVE"
          end

          File.write(DATA_FILE, JSON.pretty_generate(items))
        end
      rescue => e
        mutex.synchronize do
          puts "#{prefix} ERROR: #{e.message}"
          item["ai_filtered"] = true
          File.write(DATA_FILE, JSON.pretty_generate(items))
        end
      end
    end
  end
end

threads.each(&:join)

kept = items.count { |i| i["ai_filtered"] && i["relevant"] != false }
puts "\nDone. #{kept}/#{items.length} items kept after filtering."
