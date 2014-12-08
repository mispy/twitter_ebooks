# encoding: utf-8
require 'twitter'
require 'rufus/scheduler'

module Ebooks
  class ConfigurationError < Exception
  end

  # Represents a single reply tree of tweets
  class Conversation
    attr_reader :last_update

    # @param bot [Ebooks::Bot]
    def initialize(bot)
      @bot = bot
      @tweets = []
      @last_update = Time.now
    end

    # @param tweet [Twitter::Tweet] tweet to add
    def add(tweet)
      @tweets << tweet
      @last_update = Time.now
    end

    # Make an informed guess as to whether a user is a bot based
    # on their behavior in this conversation
    def is_bot?(username)
      usertweets = @tweets.select { |t| t.user.screen_name.downcase == username.downcase }

      if usertweets.length > 2
        if (usertweets[-1].created_at - usertweets[-3].created_at) < 30
          return true
        end
      end

      username.include?("ebooks")
    end

    # Figure out whether to keep this user in the reply prefix
    # We want to avoid spamming non-participating users
    def can_include?(username)
      @tweets.length <= 4 ||
        !@tweets[-4..-1].select { |t| t.user.screen_name.downcase == username.downcase }.empty?
    end
  end

  # Meta information about a tweet that we calculate for ourselves
  class TweetMeta
    # @return [Array<String>] usernames mentioned in tweet
    attr_accessor :mentions
    # @return [String] text of tweets with mentions removed
    attr_accessor :mentionless
    # @return [Array<String>] usernames to include in a reply
    attr_accessor :reply_mentions
    # @return [String] mentions to start reply with
    attr_accessor :reply_prefix
    # @return [Integer] available chars for reply
    attr_accessor :limit

    # @return [Ebooks::Bot] associated bot
    attr_accessor :bot
    # @return [Twitter::Tweet] associated tweet
    attr_accessor :tweet

    # Check whether this tweet mentions our bot
    # @return [Boolean]
    def mentions_bot?
      # To check if this is someone talking to us, ensure:
      # - The tweet mentions list contains our username
      # - The tweet is not being retweeted by somebody else
      # - Or soft-retweeted by somebody else
      @mentions.map(&:downcase).include?(@bot.username.downcase) && !@tweet.retweeted_status? && !@tweet.text.match(/([`'‘’"“”]|RT|via|by|from)\s*@/i)
    end

    # @param bot [Ebooks::Bot]
    # @param ev [Twitter::Tweet]
    def initialize(bot, ev)
      @bot = bot
      @tweet = ev

      @mentions = ev.attrs[:entities][:user_mentions].map { |x| x[:screen_name] }

      # Process mentions to figure out who to reply to
      # i.e. not self and nobody who has seen too many secondary mentions
      reply_mentions = @mentions.reject do |m|
        username = m.downcase
        username == @bot.username || !@bot.conversation(ev).can_include?(username)
      end
      @reply_mentions = ([ev.user.screen_name] + reply_mentions).uniq

      @reply_prefix = @reply_mentions.map { |m| '@'+m }.join(' ') + ' '
      @limit = 140 - @reply_prefix.length

      mless = ev.text
      begin
        ev.attrs[:entities][:user_mentions].reverse.each do |entity|
          last = mless[entity[:indices][1]..-1]||''
          mless = mless[0...entity[:indices][0]] + last.strip
        end
      rescue Exception
        p ev.attrs[:entities][:user_mentions]
        p ev.text
        raise
      end
      @mentionless = mless
    end
  end

  class Bot
    # @return [String] OAuth consumer key for a Twitter app
    attr_accessor :consumer_key
    # @return [String] OAuth consumer secret for a Twitter app
    attr_accessor :consumer_secret
    # @return [String] OAuth access token from `ebooks auth`
    attr_accessor :access_token
    # @return [String] OAuth access secret from `ebooks auth`
    attr_accessor :access_token_secret
    # @return [String] Twitter username of bot
    attr_accessor :username
    # @return [Array<String>] list of usernames to block on contact
    attr_accessor :blacklist
    # @return [Hash{String => Ebooks::Conversation}] maps tweet ids to their conversation contexts
    attr_accessor :conversations
    # @return [Range, Integer] range of seconds to delay in delay method
    attr_accessor :delay_range

    # @return [Array] list of all defined bots
    def self.all; @@all ||= []; end

    # Fetches a bot by username
    # @param username [String]
    # @return [Ebooks::Bot]
    def self.get(username)
      all.find { |bot| bot.username == username }
    end

    # Logs info to stdout in the context of this bot
    def log(*args)
      STDOUT.print "@#{@username}: " + args.map(&:to_s).join(' ') + "\n"
      STDOUT.flush
    end

    # Initializes and configures bot
    # @param args Arguments passed to configure method
    # @param b Block to call with new bot
    def initialize(username, &b)
      @blacklist ||= []
      @conversations ||= {}
      # Tweet ids we've already observed, to avoid duplication
      @seen_tweets ||= {}

      @username = username
      configure

      b.call(self) unless b.nil?
      Bot.all << self
    end

    # Find or create the conversation context for this tweet
    # @param tweet [Twitter::Tweet]
    # @return [Ebooks::Conversation]
    def conversation(tweet)
      conv = if tweet.in_reply_to_status_id?
        @conversations[tweet.in_reply_to_status_id]
      end

      if conv.nil?
        conv = @conversations[tweet.id] || Conversation.new(self)
      end

      if tweet.in_reply_to_status_id?
        @conversations[tweet.in_reply_to_status_id] = conv
      end
      @conversations[tweet.id] = conv

      # Expire any old conversations to prevent memory growth
      @conversations.each do |k,v|
        if v != conv && Time.now - v.last_update > 3600
          @conversations.delete(k)
        end
      end

      conv
    end

    # @return [Twitter::REST::Client] underlying REST client from twitter gem
    def twitter
      @twitter ||= Twitter::REST::Client.new do |config|
        config.consumer_key = @consumer_key
        config.consumer_secret = @consumer_secret
        config.access_token = @access_token
        config.access_token_secret = @access_token_secret
      end
    end

    # @return [Twitter::Streaming::Client] underlying streaming client from twitter gem
    def stream
      @stream ||= Twitter::Streaming::Client.new do |config|
        config.consumer_key = @consumer_key
        config.consumer_secret = @consumer_secret
        config.access_token = @access_token
        config.access_token_secret = @access_token_secret
      end
    end

    # Calculate some meta information about a tweet relevant for replying
    # @param ev [Twitter::Tweet]
    # @return [Ebooks::TweetMeta]
    def meta(ev)
      TweetMeta.new(self, ev)
    end

    # Receive an event from the twitter stream
    # @param ev [Object] Twitter streaming event
    def receive_event(ev)
      if ev.is_a? Array # Initial array sent on first connection
        log "Online!"
        return
      end

      if ev.is_a? Twitter::DirectMessage
        return if ev.sender.screen_name.downcase == @username.downcase # Don't reply to self
        log "DM from @#{ev.sender.screen_name}: #{ev.text}"
        fire(:direct_message, ev)

      elsif ev.respond_to?(:name) && ev.name == :follow
        return if ev.source.screen_name.downcase == @username.downcase
        log "Followed by #{ev.source.screen_name}"
        fire(:follow, ev.source)

      elsif ev.is_a? Twitter::Tweet
        return unless ev.text # If it's not a text-containing tweet, ignore it
        return if ev.user.screen_name.downcase == @username.downcase # Ignore our own tweets

        meta = meta(ev)

        if blacklisted?(ev.user.screen_name)
          log "Blocking blacklisted user @#{ev.user.screen_name}"
          @twitter.block(ev.user.screen_name)
        end

        # Avoid responding to duplicate tweets
        if @seen_tweets[ev.id]
          log "Not firing event for duplicate tweet #{ev.id}"
          return
        else
          @seen_tweets[ev.id] = true
        end

        if meta.mentions_bot?
          log "Mention from @#{ev.user.screen_name}: #{ev.text}"
          conversation(ev).add(ev)
          fire(:mention, ev)
        else
          fire(:timeline, ev)
        end

      elsif ev.is_a?(Twitter::Streaming::DeletedTweet) ||
            ev.is_a?(Twitter::Streaming::Event)
        # pass
      else
        log ev
      end
    end

    # Configures client and fires startup event
    def prepare
      # Sanity check
      if @username.nil?
        raise ConfigurationError, "bot username cannot be nil"
      end

      if @consumer_key.nil? || @consumer_key.empty? ||
         @consumer_secret.nil? || @consumer_key.empty?
        log "Missing consumer_key or consumer_secret. These details can be acquired by registering a Twitter app at https://apps.twitter.com/"
        exit 1
      end

      if @access_token.nil? || @access_token.empty? ||
         @access_token_secret.nil? || @access_token_secret.empty?
        log "Missing access_token or access_token_secret. Please run `ebooks auth`."
        exit 1
      end

      real_name = twitter.user.screen_name

      if real_name != @username
        log "connected to @#{real_name}-- please update config to match Twitter account name"
        @username = real_name
      end

      fire(:startup)
    end

    # Start running user event stream
    def start
      log "starting tweet stream"

      stream.user do |ev|
        receive_event ev
      end
    end

    # Fire an event
    # @param event [Symbol] event to fire
    # @param args arguments for event handler
    def fire(event, *args)
      handler = "on_#{event}".to_sym
      if respond_to? handler
        self.send(handler, *args)
      end
    end

    # Delay an action for a variable period of time
    # @param range [Range, Integer] range of seconds to choose for delay
    def delay(range=@delay_range, &b)
      time = range.to_a.sample unless range.is_a? Integer
      sleep time
      b.call
    end

    # Check if a username is blacklisted
    # @param username [String]
    # @return [Boolean]
    def blacklisted?(username)
      if @blacklist.map(&:downcase).include?(username.downcase)
        true
      else
        false
      end
    end

    # Reply to a tweet or a DM.
    # @param ev [Twitter::Tweet, Twitter::DirectMessage]
    # @param text [String] contents of reply excluding reply_prefix
    # @param opts [Hash] additional params to pass to twitter gem
    def reply(ev, text, opts={})
      opts = opts.clone

      if ev.is_a? Twitter::DirectMessage
        log "Sending DM to @#{ev.sender.screen_name}: #{text}"
        twitter.create_direct_message(ev.sender.screen_name, text, opts)
      elsif ev.is_a? Twitter::Tweet
        meta = meta(ev)

        if conversation(ev).is_bot?(ev.user.screen_name)
          log "Not replying to suspected bot @#{ev.user.screen_name}"
          return false
        end

        log "Replying to @#{ev.user.screen_name} with: #{meta.reply_prefix + text}"
        tweet = twitter.update(meta.reply_prefix + text, in_reply_to_status_id: ev.id)
        conversation(tweet).add(tweet)
        tweet
      else
        raise Exception("Don't know how to reply to a #{ev.class}")
      end
    end

    # Favorite a tweet
    # @param tweet [Twitter::Tweet]
    def favorite(tweet)
      log "Favoriting @#{tweet.user.screen_name}: #{tweet.text}"

      begin
        twitter.favorite(tweet.id)
      rescue Twitter::Error::Forbidden
        log "Already favorited: #{tweet.user.screen_name}: #{tweet.text}"
      end
    end

    # Retweet a tweet
    # @param tweet [Twitter::Tweet]
    def retweet(tweet)
      log "Retweeting @#{tweet.user.screen_name}: #{tweet.text}"

      begin
        twitter.retweet(tweet.id)
      rescue Twitter::Error::Forbidden
        log "Already retweeted: #{tweet.user.screen_name}: #{tweet.text}"
      end
    end

    # Follow a user
    # @param user [String] username or user id
    def follow(user, *args)
      log "Following #{user}"
      twitter.follow(user, *args)
    end

    # Unfollow a user
    # @param user [String] username or user id
    def unfollow(user, *args)
      log "Unfollowing #{user}"
      twiter.unfollow(user, *args)
    end

    # Tweet something
    # @param text [String]
    def tweet(text, *args)
      log "Tweeting '#{text}'"
      twitter.update(text, *args)
    end

    # Get a scheduler for this bot
    # @return [Rufus::Scheduler]
    def scheduler
      @scheduler ||= Rufus::Scheduler.new
    end

    # Tweet something containing an image
    # Only four images are allowed per tweet, but you can pass as many as you want
    # The first four to be uploaded sucessfully will be included in your tweet
    # Provide a block if you would like to modify your files before they're uploaded.
    # @param tweet_text [String] text content for tweet
    # @param pic_list [String, Array<String>] a string or array of strings containing pictures to tweet
    # @param tweet_options [Hash] options hash that will be passed along with your tweet
    # @param upload_options [Hash] options hash passed while uploading images
    # @yield [file_name] provides full filenames of files after they have been fetched, but before they're uploaded to twitter
    def pictweet(tweet_text, pic_list, tweet_options = {}, upload_options = {}, &block)
      tweet_options ||= {}
      upload_options ||= {}
      
      tweet_options.merge! Ebooks::TweetPic.process(self, pic_list, upload_options, block)
      tweet(tweet_text, tweet_options)
    end
  end

  # A singleton that uploads pictures to twitter for tweets and stuff
  module TweetPic
    # Default directory name
    DIRECTORY = 'tweet_pic_temp'
    private_constant :DIRECTORY

    # Supported filetypes and their extensions
    SUPPORTED_FILETYPES = {
      '.jpg' => '.jpg',
      '.jpeg' => '.jpg',
      'image/jpeg' => '.jpg',
      '.png' => '.png',
      'image/png' => '.png',
      '.gif' => '.gif',
      'image/gif' => '.gif'
    }

    # Exceptions
    HTTPResponseError = Class.new IOError
    FiletypeError = Class.new TypeError
    EmptyFileError = Class.new IOError
    NoUploadedFilesError = Class.new RuntimeError

    # Singleton
    class << self
      # Find directory name
      # @param directory_name [String] Set name of directory. Only does anything if a directory hasn't been made yet.
      # @return [String] name of directory
      def directory(directory_name = DIRECTORY)
        directory_name ||= DIRECTORY

        # Generate a directory name if it doesn't exist.
        unless defined? @directory_variable
          # Start out just trying to make a directory with the base name
          @directory_variable = directory_name
          current_count = 0

          # Keep looking for a folder that doesn't exist yet
          while File.exists?(@directory_variable)
            # If a folder exists, but it's empty, that's fine.
            break if Dir.exists?(pictweet_temp_folder) && Dir.entries(pictweet_temp_folder).length < 3
            # Otherwise, add 1 and keep looking.
            @directory_variable = "#{directory_name}_#{current_count.to_s}"
            current_count += 1
          end
        end

        # Create directory if it doesn't currently exist (can happen a lot).
        Dir.mkdir(@directory_variable) unless Dir.exists? @directory_variable

        @directory_variable
      end
      private :directory

      # Next file name
      # @param file_extension [String] file extension to append to filename
      # @return [String] new filename
      # @raise [Ebooks::TweetPic::FiletypeError] if extension isn't one supported by Twitter
      def file(file_extension = '')
        file_extension ||= ''

        # Add a dot if it doesn't already
        file_extension.prepend('.') unless file_extension.start_with? '.'

        # Make file_extension lowercase if it isn't already
        file_extension.downcase!

        # Raise an error if the file-extension isn't supported.
        raise FiletypeError, "'#{file_extension}' isn't as supported filetype" unless SUPPORTED_FILETYPES.has_key? file_extension

        # Increment file name
        @file_variable = @file_variable.to_i.next
        "#{@file_variable}#{file_extension}"
      end

      # Creates a scheduler
      # @return [Rufus::Scheduler]
      def scheduler
        @scheduler_variable ||= Rufus::Scheduler.new
      end
      private :scheduler

      # Find files inside directory
      # @note not to be confused with {::file}
      # @return [Array<String>] array of filenames inside directory
      def files
        # Return an empty array if directory hasn't even been made yet
        return [] unless defined? @directory_variable

        # Otherwise, return everything inside directory, minus dot elements.
        Dir.entries(directory) - ['.', '..']
      end

      # Queues a file for deletion, deletes all queued files if possible, and then deletes folder if it's empty.
      # @param trash_files [Array<String>] files to queue for deletion
      # @return [Array<String>] files still in deletion queue
      def delete(trash_files = [])
        trash_files ||= []

        # Create queue if necesscary
        @delete_queue ||= []
        # Merge trash_files into queue
        @delete_queue &= trash_files
        # Compare queue to files that are actually in directory
        @delete_queue |= files

        # Iterate through delete_queue
        @delete_queue.delete_if do |current_file|
          begin
            # Attempt to delete file
            File.delete "#{directory}/#{current_file}"
          rescue
            # Deleting file failed. Just move on.
            next false
          end
        end

        unless @delete_queue.empty?
          # Schedule another deletion in a minute.
          scheduler.in('1m') do
            delete
          end
        end

        # Remove directory if it's empty now.
        Dir.rmdir(directory) if files.empty?

        @delete_queue
      end

      # Downloads a file into directory
      # @param uri_string [String] uri of image to download
      # @return [String] filename of downloaded file
      # @raise [Ebooks::TweetPic::HTTPResponseError] if any http response other than code 200 is received
      # @raise [Ebooks::TweetPic::FiletypeError] if content-type isn't one supported by Twitter
      # @raise [Ebooks::TweetPic::EmptyFileError] if downloaded file is empty for some reason
      def download(uri_string)
        # This library is necesscary for downloads
        require 'net/http'

        # Create URI object to download file with
        uri_object = URI(uri_string)
        # Create a local variable for file name
        destination_filename = ''
        full_destination_filename = ''
        # Open download thingie
        Net::HTTP.start(uri_object.host, uri_object.port) do |http_object|
          http_object.request Net::HTTP::Get.new(uri_object) do |response_object|
            # Cancel if something goes wrong.
            raise HTTPResponseError, "'#{uri_string}' caused HTTP Error #{response_object.code}: #{response_object.msg}" unless response_object.code == '200'
            # Check file format
            content_type = response_object['content-type']
            if SUPPORTED_FILETYPES.has_key? content_type
              destination_filename = file SUPPORTED_FILETYPES[content_type]
              full_destination_filename = "#{directory}/#{destination_filename}"
            else
              raise FiletypeError, "'#{uri_string}' is an unsupported content-type: '#{content_type}'"
            end

            # Now write to file!
            open(full_destination_filename, 'w') do |file|
              response_object.read_body do |chunk|
                file.write chunk
              end
            end
          end
        end
        # If filesize is empty, something went wrong.
        downloaded_filesize = File.size(full_destination_filename)
        raise EmptyFileError, "'#{uri_string}' produced an empty file" if downloaded_filesize == 0

        # If we survived this long, everything is all set!
        destination_filename
      end
      private :download

      # Copies a file into directory
      # @param source_filename [String] relative path of image to copy
      # @return [String] filename of copied file
      def copy(source_filename)
        # Find file-extension
        if source_filename.match /(\.\w+)$/
          file_extension = $1
        end

        # Create destination filename
        destination_filename = file file_extension

        # Do copying
        FileUtils.copy(source_filename, "#{directory}/#{destination_filename}")

        destination_filename
      end
      private :copy

      # Puts a file into directory, downloading or copying as necesscary
      # @param source_file [String] relative path or internet address of image
      # @return [String] filename of file in directory
      def get(source_file)
        # Is source_file a url?
        if source_file.match /^https?:\/\//i # Starts with http(s)://, case insensitive
          download(source_file)
        else
          copy(source_file)
        end
      end

      # Allows editing of files through a block.
      # @param file_list [Array<String>] names of files to edit
      # @yield [file_name] provides full filenames of files for block to manipulate
      def edit(file_list, &block)
        # This method doesn't do anything without a block
        return unless block_given?

        # First, make sure file_list actually contains actual files.
        file_list &= files

        # Iterate over files, giving their full filenames over to the block
        file_list.each do |file_list_each|
          yield "#{directory}/#{file_list_each}"
        end
      end

      # Upload an image file to Twitter
      # @param twitter_object [Twitter] a twitter object to upload file with
      # @param file_name [String] name of file to upload
      # @return [Integer] media id from twitter
      def upload(twitter_object, file_name, upload_options = {})
        upload_options ||= {}

        # Open file stream
        file_object = File.new "#{directory}/#{file_name}"
        # Upload it
        media_id = twitter_object.upload(file_object, upload_options)
        # Close file stream
        file_object.close

        media_id
      end

      # @overload limit()
      #   Find number of images permitted per tweet
      #   @return [Integer] number of images permitted per tweet
      # @overload limit(check_list)
      #   Check if a list's length is equal to, less than, or greater than limit
      #   @param check_list [#length] object to check length of
      #   @return [Integer] difference between length and the limit, with negative values meaning length is below limit.
      # @todo See if this is is available via API, or edit this if it ever changes
      def limit(*args)
        tweet_picture_limit = 4

        case args.length
        when 0
          tweet_picture_limit
        when 1
          if args[0].respond_to? :length
            args[0].length - tweet_picture_limit
          else
            raise ArgumentError, "undefined method 'length' for #{args[0].class.to_s}"
          end
        else
          raise ArgumentError, "Incorrect number of arguments: expected 0 or 1, got #{args.length}"
        end
      end

      # Gets media ids parameter ready for a tweet
      # @param bot_object [Ebooks::Bot] an ebooks bot to upload files with
      # @param pic_list [String, Array<String>] an array of relative paths or uris to upload, or a string if there's only one
      # @param upload_options [Hash] options hash passed while uploading images
      # @param [Proc] a proc meant to be passed to {::edit}
      # @return [Hash{Symbol=>String}] A hash containing a single :media_ids key/value pair for update options
      # @raise [Ebooks::TweetPic::NoUploadedFilesError] if no files in pic_list could be uploaded
      def process(bot_object, pic_list, upload_options, block)
        # If pic_list isn't an array, make it one.
        pic_list = [pic_list] unless pic_list.is_a? Array

        # Create an array to store media IDs from Twitter
        successful_images = []
        uploaded_media_ids = []

        # Iterate over picture list
        pic_list.each do |pic_list_each|
          # Stop now if uploaded_media_ids is long enough.
          break if limit(uploaded_media_ids) >= 0

          # This entire block is wrapped in a rescue, so we can skip over things that went wrong. Errors will be dealt with later.
          begin
            # Make current image a string, just in case
            source_path = pic_list_each.to_s
            # Fetch image
            temporary_path = get(source_path)
            # Allow people to modify image
            edit([temporary_path], &block)
            # Upload image to Twitter
            uploaded_media_ids << upload(bot_object.twitter, temporary_path, upload_options)
            # If we made it this far, we've pretty much succeeded
            successful_images << source_path
            # Delete image. It's okay if this fails.
            delete([temporary_path])
          rescue
            # If something went wrong, just skip on. No need to log anything.
            next
          end
        end

        raise NoUploadedFilesError, 'None of images provided could be uploaded.' if uploaded_media_ids.empty?

        # This shouldn't be necessary, but trim down array if it needs to be.
        successful_images = successful_images[0...limit] unless limit(successful_images) < 0
        uploaded_media_ids = uploaded_media_ids[0...limit] unless limit(uploaded_media_ids) < 0

        # Report that we just uploaded images to log
        successful_images_joined = successful_images.join ' '
        bot_object.log "Uploaded to Twitter: #{successful_images_joined}"

        # Return options hash
        {:media_ids => uploaded_media_ids.join(',')}
      end
    end
  end
end