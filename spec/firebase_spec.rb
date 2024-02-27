require 'spec_helper'

describe "Firebase" do
  let (:data) do
    { 'name' => 'Oscar' }
  end

  describe "invalid uri" do
    it "should raise on http" do
      expect{ Firebase::Client.new('http://test.firebaseio.com') }.to raise_error(ArgumentError)
    end

    it 'should raise on empty' do
      expect{ Firebase::Client.new('') }.to raise_error(ArgumentError)
    end

    it "should raise when a nonrelative path is used" do
      firebase = Firebase::Client.new('https://test.firebaseio.com')
      expect { firebase.get('/path', {}) }.to raise_error(ArgumentError)
    end
  end

  before do
    @firebase = Firebase::Client.new('https://test.firebaseio.com')
  end

  describe "set" do
    it "writes and returns the data" do
      expect(@firebase).to receive(:process).with(:put, 'users/info', data, {}, {})
      @firebase.set('users/info', data)
    end
  end

  describe "get" do
    it "returns the data" do
      expect(@firebase).to receive(:process).with(:get, 'users/info', nil, {}, {})
      @firebase.get('users/info')
    end

    it "correctly passes custom ordering params" do
      params = {
        :orderBy => '"$key"',
        :startAt => '"A1"'
      }
      expect(@firebase).to receive(:process).with(:get, 'users/info', nil, params, {})
      @firebase.get('users/info', params)
    end

    it "return nil if response body contains 'null'" do
      mock_response = double(:body => 'null')
      response = Firebase::Response.new(mock_response)
      expect { response.body }.to_not raise_error
    end

    it "return true if response body contains 'true'" do
      mock_response = double(:body => 'true')
      response = Firebase::Response.new(mock_response)
      expect(response.body).to eq(true)
    end

    it "return false if response body contains 'false'" do
      mock_response = double(:body => 'false')
      response = Firebase::Response.new(mock_response)
      expect(response.body).to eq(false)
    end

    it "raises JSON::ParserError if response body contains invalid JSON" do
      mock_response = double(:body => '{"this is wrong"')
      response = Firebase::Response.new(mock_response)
      expect { response.body }.to raise_error(JSON::ParserError)
    end
  end

  describe "push" do
    it "writes the data" do
      expect(@firebase).to receive(:process).with(:post, 'users', data, {}, {})
      @firebase.push('users', data)
    end
  end

  describe "delete" do
    it "returns true" do
      expect(@firebase).to receive(:process).with(:delete, 'users/info', nil, {}, {})
      @firebase.delete('users/info')
    end
  end

  describe "update" do
    it "updates and returns the data" do
      expect(@firebase).to receive(:process).with(:patch, 'users/info', data, {})
      @firebase.update('users/info', data)
    end
  end

  describe '#transaction' do
    let(:etag_value) { 'i0Ir/zYOL6grKBc07+n2ncm/6as=' }
    let(:new_data) { {'name' => 'Oscar Wilde'} }
    let(:path) { 'users/info' }
    let(:mock_etag_response) do
      Firebase::Response.new(double({
        :body => data.to_json,
        :status => 200,
        :headers => {
          'ETag' => etag_value
        }
      }))
    end
    let(:mock_set_success_response) do
      Firebase::Response.new(double({
        :body => new_data.to_json,
        :status => 200
      }))
    end

    after(:each) do |example|
      block_data = nil
      resp = @firebase.transaction(path, max_retries: example.metadata[:max_retries]) do |data|
        block_data = JSON.parse data.to_json
        new_data
      end
      expect(block_data).to eql(data)
      if example.metadata[:max_retries].nil?
        expect(resp.body).to eql(new_data)
      else
        expect(resp.body).to eql(data)
        expect(resp.success?).to eql(false)
      end
    end

    context "data at path does not change" do
      it 'updates and returns the data' do
        expect(@firebase).to receive(:get).with(path, {}, { "X-Firebase-ETag": true }).and_return(mock_etag_response)
        expect(@firebase).to receive(:set).with(path, new_data, {}, { "if-match": etag_value }).and_return(mock_set_success_response)
      end
    end

    context "data at path changes" do
      let(:new_etag_value) { 'i0Ir/zYOL6grKBc09+n2ncm/7as=' }

      before(:each) do
        mock_set_error_response = Firebase::Response.new(double({
          :body => data.to_json,
          :status => 412,
          :headers => {
            'ETag' => new_etag_value
          }
        }))
        expect(@firebase).to receive(:get).with(path, {}, { "X-Firebase-ETag": true }).and_return(mock_etag_response)
        expect(@firebase).to receive(:set).with(path, new_data, {}, { "if-match": etag_value }).and_return(mock_set_error_response)
      end

      it "retries incase the data at path changes in the meantime" do
        expect(@firebase).to receive(:set).with(path, new_data, {}, { "if-match": new_etag_value }).and_return(mock_set_success_response)
      end

      it "does not retry after max_retries is reached", max_retries: 0 do
        expect(@firebase).not_to receive(:set).with(path, new_data, {}, { "if-match": new_etag_value })
      end
    end
  end

  describe "http processing" do
    it "sends custom auth query" do
      firebase = Firebase::Client.new('https://test.firebaseio.com', 'secret')
      expect(firebase.request).to receive(:request).with(:get, "todos.json", {
        :body => nil,
        :query => {:auth => "secret", :foo => 'bar'},
        :header => {},
        :follow_redirect => true
      })
      firebase.get('todos', :foo => 'bar')
    end
  end

  describe "service account auth" do
    before do
      credential_auth_count = 0
      @credentials = double('credentials')
      allow(@credentials).to receive(:apply!).with(instance_of(Hash)) do |arg|
        credential_auth_count += 1
        arg[:authorization] = "Bearer #{credential_auth_count}"
      end
      allow(@credentials).to receive(:issued_at) { Time.now }
      allow(@credentials).to receive(:expires_in) { 3600 }

      expect(Google::Auth::DefaultCredentials).to receive(:make_creds).with(
        json_key_io: instance_of(StringIO),
        scope: instance_of(Array)
      ).and_return(@credentials)
    end

    it "sets custom auth header" do
      client = Firebase::Client.new('https://test.firebaseio.com/', '{ "private_key": true }')
      expect(client.request.default_header).to eql({
        'Content-Type' => 'application/json',
        :authorization => 'Bearer 1'
      })
    end

    it "handles token expiry" do
      current_time = Time.now
      client = Firebase::Client.new('https://test.firebaseio.com/', '{ "private_key": true }')
      allow(Time).to receive(:now) { current_time + 3600 }
      expect(@credentials).to receive(:refresh!)
      client.get 'dummy'
      expect(client.request.default_header).to eql({
        'Content-Type' => 'application/json',
        :authorization => 'Bearer 2'
      })
    end
  end
end
