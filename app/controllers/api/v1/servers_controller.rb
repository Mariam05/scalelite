# frozen_string_literal: true

module Api
  module V1
    class ServersController < ApplicationController
      include ApiHelper

      before_action :set_server, only: [:update, :destroy, :panic]

      # Return a list of the configured BigBlueButton servers
      # GET /bigbluebutton/api/v1/servers
      #
      # Successful response:
      # [
      #   {
      #     "id": String,
      #     "url": String,
      #     "secret": String,
      #     "state": String,
      #     "load": String,
      #     "load_multiplier": String,
      #     "online": String
      #   },
      #   ...
      # ]
      def index
        servers = Server.all

        if servers.empty?
          render json: { message: 'No servers are configured' }, status: :ok
        else
          server_list = servers.map do |server|
            {
              id: server.id,
              url: server.url,
              secret: server.secret,
              state: if server.state.present?
                       server.state
                     else
                       server.enabled ? 'enabled' : 'disabled'
                     end,
              load: server.load.presence || 'unavailable',
              load_multiplier: server.load_multiplier.nil? ? 1.0 : server.load_multiplier.to_d,
              online: server.online ? 'online' : 'offline'
            }
          end

          render json: server_list, status: :ok
        end
      end

      # Add a new BigBlueButton server (it will be added disabled)
      # POST /bigbluebutton/api/v1/servers
      #
      # Expected params:
      # {
      #   "server": {
      #     "url": String,                 # Required: URL of the BigBlueButton server
      #     "secret": String,              # Required: Secret key of the BigBlueButton server
      #     "load_multiplier": Float       # Optional: A non-zero number, defaults to 1.0 if not provided or zero
      #   }
      # }
      def create
        if server_create_params[:url].blank? || server_create_params[:secret].blank?
          render json: { message: 'Error: Please input at least a URL and a secret!' }, status: :unprocessable_entity
        else
          tmp_load_multiplier = server_create_params[:load_multiplier].present? ? server_create_params[:load_multiplier].to_d : 1.0
          tmp_load_multiplier = 1.0 if tmp_load_multiplier.zero?

          server = Server.create!(url: server_create_params[:url], secret: server_create_params[:secret], load_multiplier: tmp_load_multiplier)
          render json: { message: 'OK', id: server.id }, status: :created
        end
      end

      # Update a BigBlueButton server
      # PUT /bigbluebutton/api/v1/servers/:id
      #
      # Expected params:
      # {
      #   "server": {
      #     "state": String,         # Optional: 'enable', 'cordon', or 'disable'
      #     "load_multiplier": Float # Optional: A non-zero number
      #   }
      # }
      def update
        begin
          ServerUpdateService.new(@server, server_update_params).call
          render json: { message: 'OK' }, status: :ok
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end

      # Remove a BigBlueButton server
      # DELETE /bigbluebutton/api/v1/servers/:id
      def destroy
        begin
          @server.destroy!
          render json: { message: 'OK' }, status: :ok
        rescue ApplicationRedisRecord::RecordNotDestroyed => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end

      # Set a BigBlueButton server as unavailable and clear all meetings from it
      # POST /bigbluebutton/api/v1/servers/:id/panic
      #
      # Expected params:
      # {
      #   "server": {
      #     "keep_state": Boolean # Optional: Set to 'true' if you want to keep the server's state after panicking, defaults to 'false'
      #   }
      # }
      def panic
        begin
          keep_state = (server_panic_params[:keep_state].presence || false)
          meetings = Meeting.all.select { |m| m.server_id == @server.id }
          meetings.each do |meeting|
            Rails.logger.debug { "Clearing Meeting id=#{meeting.id}" }
            moderator_pw = meeting.try(:moderator_pw)
            meeting.destroy!
            get_post_req(encode_bbb_uri('end', @server.url, @server.secret, meetingID: meeting.id, password: moderator_pw))
          rescue ApplicationRedisRecord::RecordNotDestroyed => e
            raise("ERROR: Could not destroy meeting id=#{meeting.id}: #{e}")
          rescue StandardError => e
            Rails.logger.debug { "WARNING: Could not end meeting id=#{meeting.id}: #{e}" }
          end

          @server.state = 'disabled' unless keep_state
          @server.save!
          render json: { message: 'OK' }, status: :ok
        end
      end

      # Return all meetings running in a specified BigBlueButton servers
      # If server_ids is not specified, it will return all meetings running in all servers
      # GET /bigbluebutton/api/v1/servers/meeting_list
      #
      # Successful response:
      # [
      #   {
      #     "server_id": String,
      #     "server_url": String,
      #     "meeting_ids": [
      #       String,
      #       ...
      #     ],
      #     "error": String (optional)
      #   },
      #   ...
      # ]
      def meeting_list
        server_ids = params[:server_ids].present? ? params[:server_ids].split(':') : []
        servers = server_ids.present? ? server_ids.map { |id| Server.find(id) } : Server.all

        pool = Concurrent::FixedThreadPool.new(Rails.configuration.x.poller_threads.to_i - 1, name: 'sync-meeting-data')
        tasks = servers.map do |server|
          Concurrent::Promises.future_on(pool) do
            resp = get_post_req(encode_bbb_uri('getMeetings', server.url, server.secret))
            meetings = resp.xpath('/response/meetings/meeting')
            meeting_ids = meetings.map { |meeting| meeting.xpath('.//meetingName').text }

            {
              server_id: server.id,
              server_url: server.url,
              meeting_ids: meeting_ids
            }
          rescue BBBErrors::BBBError => e
            {
              server_id: server.id,
              error: "Failed to get server status: #{e}"
            }
          rescue StandardError => e
            {
              server_id: server.id,
              error: "Failed to get meetings list status: #{e}"
            }
          end
        end

        results = Concurrent::Promises.zip_futures_on(pool, *tasks).value!(Rails.configuration.x.poller_wait_timeout)

        pool.shutdown
        pool.wait_for_termination(5) || pool.kill

        render json: results
      rescue ApplicationRedisRecord::RecordNotFound => e
        render json: { error: e.message }, status: :not_found
      end

      private

      def set_server
        begin
          @server = Server.find(params[:id])
        rescue ApplicationRedisRecord::RecordNotFound => e
          render json: { error: e.message }, status: :not_found
        end
      end

      def server_create_params
        params.require(:server).permit(:url, :secret, :load_multiplier)
      end

      def server_update_params
        params.require(:server).permit(:state, :load_multiplier)
      end

      def server_panic_params
        params.permit(:keep_state)
      end
    end
  end
end
