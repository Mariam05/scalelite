# frozen_string_literal: true

# spec/controllers/servers_controller_spec.rb

require 'rails_helper'

RSpec.describe Api::V1::ServersController, type: :controller do
  include ApiHelper

  describe 'GET #index' do
    it 'returns a list of configured BigBlueButton servers' do
      servers = create_list(:server, 3)
      get :index
      expect(response).to have_http_status(:ok)
      server_list = response.parsed_body
      expect(server_list.size).to eq(3)

      server_list.each do |server_data|
        server = servers.find { |s| s.id == server_data['id'] }
        expect(server).not_to be_nil
        expect(server_data['url']).to eq(server.url)
        expect(server_data['secret']).to eq(server.secret)
        expect(server_data['state']).to eq(if server.state.present?
                                          server.state
                                          else
                                          (server.enabled ? 'enabled' : 'disabled')
                                          end)
        expect(server_data['load']).to eq(server.load.presence || 'unavailable')
        expect(server_data['load_multiplier']).to eq(server.load_multiplier.nil? ? 1.0 : server.load_multiplier.to_d)
        expect(server_data['online']).to eq(server.online ? 'online' : 'offline')
      end
    end

    it 'returns a message if no servers are configured' do
      get :index
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['message']).to eq('No servers are configured')
    end
  end

  describe 'POST #create' do
    context 'with valid parameters' do
      let(:valid_params) {
        { url: 'https://example.com/bigbluebutton',
          secret: 'supersecret',
          load_multiplier: 1.5 }
      }

      it 'creates a new BigBlueButton server' do
        expect { post :create, params: { server: valid_params } }.to change { Server.all.count }.by(1)
        expect(response).to have_http_status(:created)
        response_data = response.parsed_body
        expect(response_data['message']).to eq('OK')
        expect(response_data['id']).to be_present
      end

      it 'defaults load_multiplier to 1.0 if not provided' do
        post :create, params: { server: valid_params.except(:load_multiplier) }
        expect(response).to have_http_status(:created)
        server = Server.find(response.parsed_body['id'])
        expect(server.load_multiplier.to_d).to eq(1.0)
      end
    end

    context 'with invalid parameters' do
      it 'renders an error message if URL is missing' do
        post :create, params: { server: { url: 'https://example.com/bigbluebutton' } }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['message']).to eq('Error: Please input at least a URL and a secret!')
      end

      it 'renders an error message if secret is missing' do
        post :create, params: { server: { secret: 'supersecret' } }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['message']).to eq('Error: Please input at least a URL and a secret!')
      end
    end
  end

  describe 'PUT #update' do
    context 'when updating state' do
      it 'updates the server state to "enabled"' do
        server = create(:server)
        put :update, params: { id: server.id, server: { state: 'enable' } }
        server = Server.find(server.id) # Reload
        expect(server.state).to eq('enabled')
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['message']).to eq('OK')
      end

      it 'updates the server state to "cordoned"' do
        server = create(:server)
        put :update, params: { id: server.id, server: { state: 'cordon' } }
        server = Server.find(server.id) # Reload
        expect(server.state).to eq('cordoned')
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['message']).to eq('OK')
      end

      it 'updates the server state to "disabled"' do
        server = create(:server)
        put :update, params: { id: server.id, server: { state: 'disable' } }
        server = Server.find(server.id) # Reload
        expect(server.state).to eq('disabled')
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['message']).to eq('OK')
      end

      it 'returns an error for an invalid state parameter' do
        server = create(:server)
        put :update, params: { id: server.id, server: { state: 'invalid_state' } }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq("Invalid state parameter: invalid_state")
      end
    end

    context 'when updating load_multiplier' do
      it 'updates the server load_multiplier' do
        server = create(:server)
        put :update, params: { id: server.id, server: { load_multiplier: '2.5' } }
        server = Server.find(server.id) # Reload
        expect(server.load_multiplier).to eq("2.5")
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['message']).to eq('OK')
      end

      it 'returns an error for an invalid load_multiplier parameter' do
        server = create(:server)
        put :update, params: { id: server.id, server: { load_multiplier: 0 } }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to eq("Load-multiplier must be a non-zero number")
      end
    end
  end

  describe 'DELETE #destroy' do
    context 'with an existing server' do
      it 'deletes the server' do
        server = create(:server)
        expect { delete :destroy, params: { id: server.id } }.to change { Server.all.count }.by(-1)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['message']).to eq('OK')
      end
    end

    context 'with a non-existent server' do
      it 'does not delete any server' do
        delete :destroy, params: { id: 'nonexistent-id' }
        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body['error']).to eq("Couldn't find Server with id=nonexistent-id")
      end
    end
  end

  describe 'POST #panic' do
    it 'marks the server as unavailable and clears all meetings from it' do
      server = create(:server)
      meeting1 = create(:meeting, server: server)
      meeting2 = create(:meeting, server: server)

      expect(Meeting.all.count).to eq(2)

      stub_params_meeting1 = {
        meetingID: meeting1.id,
        password: 'pw',
      }

      stub_params_meeting2 = {
        meetingID: meeting2.id,
        password: 'pw',
      }

      stub_request(:get, encode_bbb_uri("end", server.url, server.secret, stub_params_meeting1))
        .to_return(body: "<response><returncode>FAILED</returncode><messageKey>notFound</messageKey>
                            <message>We could not find a meeting with that meeting ID - perhaps the meeting is not yet running?
                            </message></response>")

      stub_request(:get, encode_bbb_uri("end", server.url, server.secret, stub_params_meeting2))
        .to_return(body: "<response><returncode>FAILED</returncode><messageKey>notFound</messageKey>
                            <message>We could not find a meeting with that meeting ID - perhaps the meeting is not yet running?
                          </message></response>")

      post :panic, params: { id: server.id }

      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json['message']).to eq('OK')
      server = Server.find(server.id) # Reload
      expect(server.state).to eq('disabled')
      expect(Meeting.all.count).to eq(0)
    end

    it 'keeps server state if keep_state is true' do
      server = create(:server, state: 'enabled')

      post :panic, params: { id: server.id, keep_state: true }

      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json['message']).to eq('OK')
      server = Server.find(server.id) # Reload
      expect(server.state).to eq('enabled')
      expect(Meeting.all.count).to eq(0)
    end

    it 'returns an error message if the server is not found' do
      post :panic, params: { id: 'nonexistent_id' }

      expect(response).to have_http_status(:not_found)
      json = response.parsed_body
      expect(json['error']).to eq("Couldn't find Server with id=nonexistent_id")
    end
  end

  describe 'GET #meeting_list' do
    it 'returns a list of meetings for all servers' do
      server1 = create(:server)
      server2 = create(:server)

      stub_request(:get, encode_bbb_uri("getMeetings", server1.url, server1.secret))
        .to_return(body: "<response><returncode>SUCCESS</returncode><meetings>
                          <meeting><meetingName>Meeting 1</meetingName></meeting>
                          <meeting><meetingName>Meeting 2</meetingName></meeting><
                          /meetings></response>")

      stub_request(:get, encode_bbb_uri("getMeetings", server2.url, server2.secret))
        .to_return(body: "<response><returncode>SUCCESS</returncode><meetings>
                          <meeting><meetingName>Meeting 3</meetingName></meeting></meetings></response>")

      get :meeting_list

      expect(response).to have_http_status(:success)
      json = response.parsed_body
      expect(json.length).to eq(2)

      # Need to be order-agnostic because of the concurrency
      server1_data = {
        'server_id' => server1.id,
        'server_url' => server1.url,
        'meeting_ids' => contain_exactly('Meeting 1', 'Meeting 2')
      }
      server2_data = {
        'server_id' => server2.id,
        'server_url' => server2.url,
        'meeting_ids' => contain_exactly('Meeting 3')
      }

      expect(json).to include(server1_data)
      expect(json).to include(server2_data)
    end

    it 'returns a list of meetings for a specific server' do
      server = create(:server)

      stub_request(:get, encode_bbb_uri("getMeetings", server.url, server.secret))
        .to_return(body: "<response><returncode>SUCCESS</returncode><meetings>
                          <meeting><meetingName>Meeting 1</meetingName></meeting>
                          <meeting><meetingName>Meeting 2</meetingName></meeting>
                          </meetings></response>")

      get :meeting_list, params: { server_ids: server.id.to_s }

      expect(response).to have_http_status(:success)
      json = response.parsed_body
      expect(json.length).to eq(1)
      expect(json[0]['server_id']).to eq(server.id)
      expect(json[0]['meeting_ids']).to contain_exactly('Meeting 1', 'Meeting 2')
    end

    it 'returns an error message if a server cannot be found' do
      get :meeting_list, params: { server_ids: 'nonexistent-id' }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['error']).to eq("Couldn't find Server with id=nonexistent-id")
    end
  end
end
