# frozen_string_literal: true

require 'fileutils'
require 'optparse'
require 'pathname'
require 'uri'
require 'pastel'
require 'tty-progressbar'
require 'tty-spinner'

require_relative 'api'
require_relative 'clipboard'

module Catbox
  class CLI
    VERSION = '3.0.0'
    HASH_FILE = File.expand_path('~/.catbox')
    EXPIRIES = %w[1h 12h 24h 72h].freeze
    HELP_COMMAND_WIDTH = 35
    ALBUM_HELP_COMMAND_WIDTH = 50
    HELP_OPTION_WIDTH = 25
    COMMAND_HANDLERS = {
      'version' => :version,
      'help' => :help_command,
      'usage' => :help_command,
      'user' => :user_command,
      'file' => :file_command,
      'temp' => :temp_command,
      'url' => :url_command,
      'delete' => :delete_command,
      'album' => :album_command
    }.freeze

    def initialize(argv, out: $stdout, err: $stderr, api: Api.new)
      @argv = argv.dup
      @out = out
      @err = err
      @api = api
      @options = { color: true, silent: false, silent_all: false, verbose: false }
      @pastel = Pastel.new(enabled: true)
    end

    def call
      with_error_handling { run }
    end

    private

    def run
      parse_global_options
      refresh_color
      dispatch_command(@argv.shift)
    end

    def dispatch_command(command)
      return usage(code: 1) if command.nil?

      handler = COMMAND_HANDLERS[command]
      return usage("Unknown command: #{command}", code: 1) unless handler

      send(handler)
    end

    def with_error_handling
      yield
    rescue Interrupt
      handle_interrupt
    rescue StandardError => e
      handle_cli_error(e)
    end

    def handle_cli_error(exception)
      case exception
      when OptionParser::ParseError then handle_parse_error(exception)
      when Api::ApiError then handle_api_error(exception)
      when SystemCallError then handle_system_error(exception)
      else handle_unexpected_error(exception)
      end
    end

    def refresh_color
      @pastel = Pastel.new(enabled: @options[:color])
    end

    def parse_global_options
      global_option_parser.permute!(@argv)
    end

    def global_option_parser
      OptionParser.new do |opts|
        add_output_options(opts)
        add_user_options(opts)
        add_command_shortcuts(opts)
      end
    end

    def add_output_options(opts)
      opts.on('-s', '--silent') { @options[:silent] = true }
      opts.on('-S', '--silent-all') { @options[:silent] = @options[:silent_all] = true }
      opts.on('-n', '--no-color') { @options[:color] = false }
      opts.on('-V', '--verbose') { @options[:verbose] = true }
    end

    def add_user_options(opts)
      opts.on('-uHASH', '--user-hash=HASH') { |hash| @options[:hash] = hash }
    end

    def add_command_shortcuts(opts)
      opts.on('-v', '--version') { @argv = ['version'] }
      opts.on('-h', '--help', '--usage') { @argv = ['help'] }
    end

    def version
      say "#{strong('CatBox')} v#{VERSION}"
      say 'A catbox.moe API implementation in Ruby'
      0
    end

    def help_command
      usage
    end

    def usage(message = nil, code: 0)
      error(message) if message
      stream = code.zero? ? @out : @err
      stream.puts if message
      print_usage_header(stream)
      print_usage_commands(stream)
      print_usage_options(stream)
      code
    end

    def user_command
      value = @argv.shift
      return usage('Usage: catbox user [hash|off]', code: 1) unless @argv.empty?
      return show_user_hash if value.nil?
      return clear_user_hash if value == 'off'

      save_user_hash(value)
    end

    def file_command
      if @argv.empty?
        return usage('Usage: catbox file <filename> [<filename>...] - Upload files to catbox.moe',
                     code: 1)
      end

      say(user_hash ? 'Uploading...' : 'Uploading anonymously...')
      failures = upload_files(Api::CATBOX_HOST, @argv, fields: catbox_fields)
      failures == @argv.length ? 2 : 0
    end

    def temp_command
      return usage('Usage: catbox temp <filename> [<filename>...] [1h/12h/24h/72h]', code: 1) if @argv.empty?

      expiry = EXPIRIES.include?(@argv.last) ? @argv.pop : '1h'
      invalid_expiry = @argv.find { |arg| expiry_argument?(arg) && !EXPIRIES.include?(arg) }
      return usage("Invalid expiry '#{invalid_expiry}'. Use one of: #{EXPIRIES.join(', ')}", code: 1) if invalid_expiry

      say 'Uploading temporarily...'
      failures = upload_files(Api::LITTER_HOST, @argv, fields: { time: expiry })
      failures == @argv.length ? 2 : 0
    end

    def url_command
      return usage('Usage: catbox url <url> [<url>...] - Upload files from URLs to catbox.moe', code: 1) if @argv.empty?

      url_validation_error = validate_urls
      return usage(url_validation_error, code: 1) if url_validation_error

      say(user_hash ? 'Uploading...' : 'Uploading anonymously...')
      failures = generic_each(@argv, label: ->(url) { url_label(url) }, reqtype: 'urlupload', field: :url) do |res|
        Catbox::Clipboard.copy(res)
        say res, force: true
      end
      failures == @argv.length ? 2 : 0
    end

    def delete_command
      if @argv.empty?
        return usage('Usage: catbox delete <filename> [<filename>...] - Delete files from your account',
                     code: 1)
      end
      return no_hash! unless user_hash

      say 'Deleting...'
      failures = generic_each(@argv, label: ->(item) { item }, reqtype: 'deletefiles', field: :files) do
        say 'Successfully deleted'
      end
      failures == @argv.length ? 2 : 0
    end

    def album_command
      return album_usage(1) if @argv.empty?

      subcommand = @argv.shift
      case subcommand
      when 'create', 'edit', 'add', 'remove', 'delete'
        return no_hash! unless user_hash

        send(:"album_#{subcommand}")
      else album_usage(1, "Unknown album command: #{subcommand}")
      end
    end

    def album_create
      return album_create_usage if @argv.length < 3

      title, desc, *files = @argv
      verbose_album('Creating album...', album_values(title, desc, files))
      album = create_album(title, desc, files)
      Catbox::Clipboard.copy(album)
      say "\nAlbum created successfully"
      say(album_success_message(album), force: true)
      0
    end

    def album_edit
      return album_edit_usage if @argv.length < 3

      short, title, desc, *files = @argv
      verbose_album('Modifying album...', album_values(title, desc, files).merge('Album Short' => short))
      edit_album(short, title, desc, files)
      say "\nAlbum modified successfully"
      0
    end

    def album_add
      album_files('addtoalbum', 'Adding files to the album...', "\nSuccessfully added files to the album")
    end

    def album_remove
      album_files('removefromalbum', 'Removing files from the album...', "\nSuccessfully removed files from the album")
    end

    def album_delete
      return usage('Usage: catbox album delete <short> [<short> ...] - Delete album(s)', code: 1) if @argv.empty?

      say 'Deleting albums...'
      failures = generic_each(@argv, label: ->(item) { item }, reqtype: 'deletealbum', field: :short) do
        say 'Successfully deleted'
      end
      failures == @argv.length ? 2 : 0
    end

    def album_files(reqtype, intro, success)
      return usage('Usage: catbox album add/remove <short> <filename> [<filename> ...]', code: 1) if @argv.length < 2

      short, *files = @argv
      verbose_album(intro, 'Album short' => short, 'Files' => files.join(' '))
      with_progress(intro.delete_suffix('...'), 1) do |progress|
        request(reqtype: reqtype, fields: catbox_fields.merge(short: short, files: files.join(' ')))
        advance_progress(progress)
      end
      say success
      0
    end

    def upload_files(host, files, fields:)
      with_progress('Files', files.length) do |progress|
        files.count { |file| upload_file(host, file, fields, progress) }
      end
    end

    def generic_each(items, label:, reqtype:, field:, &block)
      with_progress('Items', items.length) do |progress|
        items.count { |item| process_item(item, label, reqtype, field, progress, &block) }
      end
    end

    def upload_file(host, file, fields, progress)
      say "#{strong(file_label(file))}:"
      return missing_file?(file, progress) unless uploadable_file?(file)

      link = request(host: host, reqtype: 'fileupload', fields: fields, file: file)
      uploaded_file_failed?(link, progress)
    rescue Api::ApiError => e
      upload_failed?(e, progress)
    end

    def uploaded_file_failed?(link, progress)
      Catbox::Clipboard.copy(link)
      say "Uploaded to: #{strong(link)}", force: true
      advance_progress(progress)
      false
    end

    def upload_failed?(exception, progress)
      error "Failed to upload: #{exception.message}"
      advance_progress(progress)
      true
    end

    def file_label(file)
      file == '-' ? 'stdin' : File.basename(file)
    end

    def uploadable_file?(file)
      file == '-' || File.file?(file) || File.symlink?(file)
    end

    def missing_file?(file, progress)
      error strong("File '#{file}' doesn't exist!")
      advance_progress(progress)
      true
    end

    def process_item(item, label, reqtype, field, progress)
      say "#{strong(label.call(item))}: ", newline: false
      res = request(reqtype: reqtype, fields: catbox_fields.merge(field => item))
      yield(res)
      advance_progress(progress)
      false
    rescue Api::ApiError => e
      item_failed?(item, e, progress)
    end

    def item_failed?(item, exception, progress)
      error "#{item}: #{exception.message}"
      advance_progress(progress)
      true
    end

    def handle_parse_error(exception)
      refresh_color
      usage(exception.message, code: 1)
    end

    def handle_api_error(exception)
      error(exception.message)
      2
    end

    def handle_interrupt
      error('Cancelled.')
      130
    end

    def handle_system_error(exception)
      error("File system error: #{exception.message}")
      2
    end

    def handle_unexpected_error(exception)
      error("Unexpected error: #{exception.message}")
      unless @options[:verbose]
        error('Run again with --verbose for a backtrace.')
        return 2
      end

      @err.puts(exception.backtrace.join("\n")) if exception.backtrace
      2
    end

    def clear_user_hash
      FileUtils.rm_f(HASH_FILE)
      say 'CatBox will now upload anonymously'
      0
    end

    def save_user_hash(value)
      File.write(HASH_FILE, "# CatBox Ruby User Hash\n#{value}\n", mode: 'w', perm: 0o600)
      say "User hash set!\nCatBox will now upload files to your account"
      0
    end

    def request(reqtype:, fields:, host: Api::CATBOX_HOST, file: nil)
      if @options[:silent] || @progress_active
        return @api.request(host: host, reqtype: reqtype, fields: fields,
                            file: file)
      end

      spinner = TTY::Spinner.new('[:spinner] Please wait...', output: @err, hide_cursor: true)
      spinner.auto_spin
      @api.request(host: host, reqtype: reqtype, fields: fields, file: file)
    ensure
      spinner&.success('(done)') unless @options[:silent]
    end

    def with_progress(title, total)
      return yield(nil) if @options[:silent] || total < 1

      @progress_active = true
      bar = TTY::ProgressBar.new("#{title} [:bar] :current/:total :percent", total: total, output: @err)
      yield(bar)
    ensure
      @progress_active = false
    end

    def advance_progress(progress)
      progress&.advance
    end

    def catbox_fields
      hash = user_hash
      hash ? { userhash: hash } : {}
    end

    def user_hash
      return @options[:hash] if @options[:hash]
      return nil unless File.file?(HASH_FILE)

      File.readlines(HASH_FILE, chomp: true).find { |line| !line.empty? && !line.start_with?('#') }
    end

    def no_hash!
      error strong('No user hash!')
      error 'Please add your user hash with `catbox user <hash>`'
      1
    end

    def show_user_hash
      hash = user_hash
      message = hash ? "User hash present!\nUser hash: #{hash}\nCatBox will act as you" : anonymous_user_message
      say(message)
      0
    end

    def anonymous_user_message
      "No user hash\nCatBox will act anonymously"
    end

    def print_usage_header(stream)
      usage_parts = [
        heading('Usage:'),
        command_name('catbox'),
        argument('<command>'),
        argument('[arguments]'),
        argument('[options]')
      ]
      stream.puts usage_parts.join(' ')
    end

    def print_usage_commands(stream)
      stream.puts
      stream.puts heading('Commands:')
      usage_commands.each { |row| help_row(stream, *row) }
    end

    def usage_commands
      [
        ['user', '[hash|off]', 'Show, save, or remove your user hash'],
        ['file', '<file...>', 'Upload one or more local files'],
        ['temp', '<file...> [1h|12h|24h|72h]', 'Upload temporary files'],
        ['url', '<url...>', 'Upload files from direct URLs'],
        ['delete', '<file...>', 'Delete files from your account'],
        ['album', '<command>', 'Manage albums']
      ]
    end

    def print_usage_options(stream)
      stream.puts
      stream.puts heading('Global options:')
      usage_options.each { |row| option_row(stream, *row) }
    end

    def usage_options
      [
        ['-s, --silent', 'Only print result links'],
        ['-S, --silent-all', 'Hide normal output and errors'],
        ['-n, --no-color', 'Turn off colored output'],
        ['-u, --user-hash HASH', 'Use this hash for the command'],
        ['-V, --verbose', 'Show more album details']
      ]
    end

    def validate_urls
      invalid_url = @argv.find { |url| !valid_url?(url) }
      return "Invalid URL: #{invalid_url}" if invalid_url

      non_file_url = @argv.find { |url| url_label(url).empty? }
      "URL must point directly to a file: #{non_file_url}" if non_file_url
    end

    def expiry_argument?(value)
      value.match?(/\A\d+h\z/)
    end

    def valid_url?(value)
      uri = URI.parse(value)
      uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
    rescue URI::InvalidURIError
      false
    end

    def url_label(value)
      File.basename(URI(value).path.to_s)
    end

    def album_create_usage
      usage('Usage: catbox album create <title> <description> <filename> [<filename> ...]', code: 1)
    end

    def album_edit_usage
      usage('Usage: catbox album edit <short> <title> <description> [<filename> ...]', code: 1)
    end

    def album_values(title, desc, files)
      {
        'Title' => title,
        'Description' => desc,
        'Files' => files.join(' ')
      }
    end

    def create_album(title, desc, files)
      with_progress('Creating album', 1) do |progress|
        request(reqtype: 'createalbum', fields: album_fields(title, desc, files)).tap do
          advance_progress(progress)
        end
      end
    end

    def edit_album(short, title, desc, files)
      with_progress('Modifying album', 1) do |progress|
        request(reqtype: 'editalbum', fields: album_fields(title, desc, files).merge(short: short))
        advance_progress(progress)
      end
    end

    def album_fields(title, desc, files)
      catbox_fields.merge(title: title, desc: desc, files: files.join(' '))
    end

    def album_success_message(album)
      short = album.split('/').last
      return "Album short: #{short}\nAlbum url  : #{album}" if @options[:verbose]

      "#{short} | #{album}"
    end

    def album_usage(code, message = nil)
      error(message) if message
      stream = code.zero? ? @out : @err
      stream.puts if message
      print_album_usage_header(stream)
      print_album_usage_commands(stream)
      code
    end

    def print_album_usage_header(stream)
      usage_parts = [heading('Usage:'), command_name('catbox album'), argument('<command>'), argument('[arguments]')]
      stream.puts usage_parts.join(' ')
      stream.puts
      stream.puts strong(warn_text('Note: Every album command requires user hash')).to_s
      stream.puts '      For title or description, quote text longer than one word'
    end

    def print_album_usage_commands(stream)
      stream.puts
      stream.puts heading('Commands:')
      album_usage_commands.each { |row| help_row(stream, *row, width: ALBUM_HELP_COMMAND_WIDTH) }
    end

    def album_usage_commands
      [
        ['create', '<title> <description> <file(s)>', 'Create album'],
        ['edit', '<short> <title> <description> [file(s)]', 'Modify album'],
        ['add', '<short> <file(s)>', 'Add files to an album'],
        ['remove', '<short> <file(s)>', 'Remove files from an album'],
        ['delete', '<short>', 'Delete album']
      ]
    end

    def verbose_album(intro, values)
      say intro
      return unless @options[:verbose]

      values.each { |key, value| say "#{key.ljust(11)}: #{value}", force: true }
    end

    def say(message, force: false, newline: true)
      return if @options[:silent] && !force

      @out.public_send(newline ? :puts : :print, message)
    end

    def error(message)
      return if @options[:silent_all]

      @err.puts red(message)
    end

    def help_row(stream, name, args, description, width: HELP_COMMAND_WIDTH)
      raw_parts = [name, args].reject(&:empty?)
      styled_parts = [command_name(name)]
      styled_parts << argument(args) unless args.empty?

      raw = raw_parts.join(' ')
      styled = styled_parts.join(' ')
      stream.puts "   #{styled}#{padding_for(raw, width)} - #{description}"
    end

    def option_row(stream, flags, description)
      stream.puts "   #{option_name(flags)}#{padding_for(flags, HELP_OPTION_WIDTH)} - #{description}"
    end

    def padding_for(text, width)
      ' ' * [width - text.length, 1].max
    end

    def heading(text)
      @pastel.bold.bright_blue(text)
    end

    def command_name(text)
      @pastel.green(text)
    end

    def option_name(text)
      @pastel.cyan(text)
    end

    def argument(text)
      @pastel.yellow(text)
    end

    def strong(text)
      @pastel.bold(text)
    end

    def red(text)
      @pastel.red(text)
    end

    def warn_text(text)
      @pastel.yellow(text)
    end
  end
end
