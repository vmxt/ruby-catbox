# frozen_string_literal: true

require 'tmpdir'
require 'tempfile'
require 'fileutils'

CatboxCliFakeApi = Struct.new(:response, :requests, keyword_init: true) do
  def request(**kwargs)
    requests << kwargs
    response
  end
end

CatboxCliInterruptApi = Struct.new(:requests, keyword_init: true) do
  def request(**kwargs)
    requests << kwargs
    raise Interrupt
  end
end

RSpec.describe Catbox::CLI do
  def run_cli(argv, api: CatboxCliFakeApi.new(response: 'https://files.catbox.moe/demo.txt', requests: []))
    out = StringIO.new
    err = StringIO.new
    code = described_class.new(argv, out: out, err: err, api: api).call

    [code, out.string, err.string, api]
  end

  let(:tmpdir) { Dir.mktmpdir }

  before do
    stub_const("#{described_class}::HASH_FILE", File.join(tmpdir, '.catbox'))
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  describe 'help' do
    it 'prints easy command descriptions without color' do
      code, out, = run_cli(%w[help --no-color])

      expect(code).to eq(0)
      expect(out).to include('Usage: catbox <command> [arguments] [options]')
      expect(out).to include('file <file...>                      - Upload one or more local files')
      expect(out).to include('-u, --user-hash HASH      - Use this hash for the command')
    end

    it 'prints usage for unknown commands' do
      code, _out, err = run_cli(%w[wat --no-color])

      expect(code).to eq(1)
      expect(err).to include('Unknown command: wat')
      expect(err).to include('Usage: catbox <command> [arguments] [options]')
    end
  end

  describe 'global options' do
    it 'accepts options before the command' do
      code, out, = run_cli(%w[--no-color --user-hash TESTHASH user])

      expect(code).to eq(0)
      expect(out).to include('User hash: TESTHASH')
    end

    it 'accepts options after the command' do
      code, out, = run_cli(%w[user -u TESTHASH --no-color])

      expect(code).to eq(0)
      expect(out).to include('User hash: TESTHASH')
    end

    it 'suppresses normal output with silent mode' do
      code, out, err = run_cli(%w[user --silent --user-hash TESTHASH])

      expect(code).to eq(0)
      expect(out).to be_empty
      expect(err).to be_empty
    end

    it 'prints usage for unknown options' do
      code, _out, err = run_cli(%w[--no-color file example.txt --bad-option])

      expect(code).to eq(1)
      expect(err).to include('invalid option: --bad-option')
      expect(err).to include('Usage: catbox <command> [arguments] [options]')
    end
  end

  describe 'user hash' do
    it 'rejects extra arguments' do
      code, _out, err = run_cli(%w[user HASH extra --no-color])

      expect(code).to eq(1)
      expect(err).to include('Usage: catbox user [hash|off]')
    end
  end

  describe 'file uploads' do
    it 'uploads a local file with the configured hash' do
      Tempfile.create('catbox-spec') do |file|
        file.write('hello')
        file.close

        api = CatboxCliFakeApi.new(response: 'https://files.catbox.moe/spec.txt', requests: [])
        code, out, _err, api = run_cli(['file', file.path, '--silent', '--user-hash', 'HASH'], api: api)

        expect(code).to eq(0)
        expect(out).to include('https://files.catbox.moe/spec.txt')
        expect(api.requests.first).to include(
          host: Catbox::Api::CATBOX_HOST,
          reqtype: 'fileupload',
          fields: { userhash: 'HASH' },
          file: file.path
        )
      end
    end

    it 'returns failure when every file is missing' do
      code, _out, err = run_cli(%w[file missing.txt --no-color])

      expect(code).to eq(2)
      expect(err).to include("File 'missing.txt' doesn't exist!")
    end
  end

  describe 'temporary uploads' do
    it 'uses the selected expiry' do
      Tempfile.create('catbox-spec') do |file|
        file.close

        api = CatboxCliFakeApi.new(response: 'https://litter.catbox.moe/spec.txt', requests: [])
        code, = run_cli(['temp', file.path, '12h', '--silent'], api: api)

        expect(code).to eq(0)
        expect(api.requests.first).to include(
          host: Catbox::Api::LITTER_HOST,
          reqtype: 'fileupload',
          fields: { time: '12h' },
          file: file.path
        )
      end
    end

    it 'rejects invalid expiry values' do
      code, _out, err = run_cli(%w[temp scratch.log 2h --no-color])

      expect(code).to eq(1)
      expect(err).to include("Invalid expiry '2h'. Use one of: 1h, 12h, 24h, 72h")
    end
  end

  describe 'URL uploads' do
    it 'rejects invalid URLs before making a request' do
      code, _out, err, api = run_cli(%w[url not-a-url --no-color])

      expect(code).to eq(1)
      expect(err).to include('Invalid URL: not-a-url')
      expect(api.requests).to be_empty
    end

    it 'rejects URLs that do not point directly to a file' do
      code, _out, err, api = run_cli(%w[url https://google.com --no-color])

      expect(code).to eq(1)
      expect(err).to include('URL must point directly to a file: https://google.com')
      expect(api.requests).to be_empty
    end

    it 'handles Ctrl-C without printing a backtrace' do
      api = CatboxCliInterruptApi.new(requests: [])
      code, _out, err = run_cli(%w[url https://example.com/file.txt --no-color], api: api)

      expect(code).to eq(130)
      expect(err).to include('Cancelled.')
      expect(err).not_to include('lib/catbox')
    end
  end

  describe 'album commands' do
    it 'prints album usage for unknown album commands' do
      code, _out, err = run_cli(%w[album creat --no-color])

      expect(code).to eq(1)
      expect(err).to include('Unknown album command: creat')
      expect(err).to include('Usage: catbox album <command> [arguments]')
    end
  end
end
