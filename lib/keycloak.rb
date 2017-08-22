require 'keycloak/version'
require 'rest-client'
require 'json'
require 'jwt'
require 'base64'
require 'uri'

module Keycloak

	class << self
		attr_accessor :proxy, :generate_request_exception, :keycloak_controller,
		              :proc_cookie_token, :proc_external_attributes
	end


	def self.explode_exception
		if Keycloak.generate_request_exception == nil
			Keycloak.generate_request_exception = true
		end
		Keycloak.generate_request_exception
	end

	module Client

		class << self
			attr_reader :realm, :url, :client_id, :auth_server_url,
						:secret, :configuration, :public_key

		end

		KEYCLOAK_JSON_FILE = 'keycloak.json'

		def self.get_token(user, password)
			setup_module

			payload = {'client_id' => @client_id,
					   'client_secret' => @secret,
					   'username' => user,
					   'password' => password,
					   'grant_type' => 'password'
					  }

			mount_request_token(payload)
		end

		def self.get_token_by_code(code, redirect_uri)
			verify_setup

			payload = {'client_id' => @client_id,
					   'client_secret' => @secret,
					   'code' => code,
					   'grant_type' => 'authorization_code',
					   'redirect_uri' => redirect_uri
					  }

			mount_request_token(payload)
		end

		def self.get_token_by_refresh_token(refreshToken = '')
			verify_setup

			refreshToken = self.token['refresh_token'] if refreshToken.empty?

			payload = {'client_id' => @client_id,
					   'client_secret' => @secret,
					   'refresh_token' => refreshToken,
					   'grant_type' => 'refresh_token'
					  }

			mount_request_token(payload)
		end

		def self.get_token_by_client_credentials
			setup_module

			payload = {'client_id' => @client_id,
					   'client_secret' => @secret,
					   'grant_type' => 'client_credentials'
					  }

			mount_request_token(payload)
		end

		def self.get_token_introspection(token = '')
			verify_setup

			token = self.token["access_token"] if token.empty?

			payload = {'token' => token}

			authorization = Base64.strict_encode64("#{@client_id}:#{@secret}")
			authorization = "Basic #{authorization}"

			header = {'Content-Type' => 'application/x-www-form-urlencoded',
								'authorization' => authorization}

			_request = -> do
				RestClient.post(@configuration['token_introspection_endpoint'], payload, header){|response, request, result|
					case response.code
					when 200..399
						response.body

					else
						response.return!
					end
				}
			end

			exec_request _request
		end

		def self.url_login_redirect(redirect_uri, response_type = 'code')
			verify_setup

			p = URI.encode_www_form({:response_type => response_type, :client_id => @client_id, :redirect_uri => redirect_uri})
			"#{@configuration['authorization_endpoint']}?#{p}"
		end

		def self.logout(redirect_uri = '', refresh_token = '')
			verify_setup

			if self.token || !refresh_token.empty?

				refresh_token = self.token['refresh_token'] if refresh_token.empty?

				payload = {'client_id' => @client_id,
						   'client_secret' => @secret,
						   'refresh_token' => refresh_token
						  }

				header = {'Content-Type' => 'application/x-www-form-urlencoded'}

				if redirect_uri.empty?
					final_url = @configuration['end_session_endpoint']
				else
					final_url = "#{@configuration['end_session_endpoint']}?#{URI.encode_www_form({:redirect_uri => redirect_uri})}"
				end

				_request = -> do
					RestClient.post(final_url, payload, header){|response, request, result|
						case response.code
						when 200..399
							true
						else
							response.return!
						end
					}
				end

				exec_request _request
			else
				true
			end
		end

		def self.get_userinfo(accessToken = '')
			verify_setup

			accessToken = self.token["access_token"] if accessToken.empty?

			payload = {'access_token' => accessToken}

			header = {'Content-Type' => 'application/x-www-form-urlencoded'}

			_request = -> do
				RestClient.post(@configuration['userinfo_endpoint'], payload, header){|response, request, result|
					case response.code
					when 200
						response.body
					else
						response.return!
					end
				}
			end

			exec_request _request
		end

		def self.url_user_account
			verify_setup

			"#{@url}/realms/#{@realm}/account"
		end

		def self.has_role?(userRole, accessToken = '')
			verify_setup

			if user_signed_in?(accessToken)
				dt = decoded_access_token(accessToken)[0]
				dt = dt["resource_access"][@client_id]
				if dt != nil
					dt["roles"].each do |role|
						return true if role.to_s == userRole.to_s
					end
					false
				else
					false
				end
			else
				false
			end
		end

		def self.user_signed_in?(accessToken = '')
			verify_setup

			begin
				JSON(get_token_introspection(accessToken))['active'] === true
			rescue => e
				if e.class < Keycloak::KeycloakException
					raise
				else
					false
				end
			end
		end

		def self.get_attribute(attributeName, accessToken = '')
			verify_setup

			attr = decoded_access_token(accessToken)[0]
			attr[attributeName]
		end

		def self.token
			unless Keycloak.proc_cookie_token.nil?
				JSON Keycloak.proc_cookie_token.call
			else
				raise Keycloak::ProcCookieTokenNotDefined
			end
		end

		def self.external_attributes
			unless Keycloak.proc_external_attributes.nil?
				Keycloak.proc_external_attributes.call
			else
				raise Keycloak::ProcExternalAttributesNotDefined
			end
		end

		private

			KEYCLOACK_CONTROLLER_DEFAULT = 'session'

			def self.get_installation
				if File.exists?(KEYCLOAK_JSON_FILE)
					installation = JSON File.read(KEYCLOAK_JSON_FILE)
					@realm = installation["realm"]
					@url = installation["auth-server-url"]
					@client_id = installation["resource"]
					@secret = installation["credentials"]["secret"]
					@public_key = installation["realm-public-key"]
					@auth_server_url = installation["auth-server-url"]
					openid_configuration
				else
					raise "#{KEYCLOAK_JSON_FILE} not found."
				end
			end

			def self.verify_setup
				get_installation if @configuration.nil?
			end

			def self.setup_module
				Keycloak.proxy ||= ''
				Keycloak.keycloak_controller ||= KEYCLOACK_CONTROLLER_DEFAULT
				get_installation
			end

			def self.exec_request(proc_request)
				if Keycloak.explode_exception
					proc_request.call
				else
					begin
						proc_request.call
					rescue RestClient::ExceptionWithResponse => err
						err.response
					end
				end
			end

			def self.openid_configuration
				RestClient.proxy = Keycloak.proxy unless Keycloak.proxy.empty?
				configUrl = "#{@url}/realms/#{@realm}/.well-known/openid-configuration"
				_request = -> do
					RestClient.get configUrl
				end
				response = exec_request _request
				if response.code == 200
					@configuration = JSON response.body
				else
					response.return!
				end
			end

			def self.mount_request_token(payload)
				header = {'Content-Type' => 'application/x-www-form-urlencoded'}

				_request = -> do
					RestClient.post(@configuration['token_endpoint'], payload, header){|response, request, result|
						case response.code
						when 200
							response.body
						else
							response.return!
						end
					}
				end

				exec_request _request
			end

			def self.decoded_access_token(accessToken = '')
				accessToken = self.token["access_token"] if accessToken.empty?
				JWT.decode accessToken, @public_key, false, { :algorithm => 'RS256' }
			end

			def self.decoded_refresh_token(refreshToken = '')
				refreshToken = self.token["access_token"] if refreshToken.empty?
				JWT.decode refreshToken, @public_key, false, { :algorithm => 'RS256' }
			end

			def self.decoded_id_token(idToken = '')
				tk = self.token
				idToken = tk["id_token"] if idToken.empty?
				if idToken
					@decoded_id_token = JWT.decode idToken, @public_key, false, { :algorithm => 'RS256' }
				end
			end

	end

	# Os recursos desse module (admin) serão utilizadas apenas por usuários que possuem as roles do client realm-management
	module Admin

		class << self

		end

		def self.get_users( queryParameters = nil)
			generic_get("users/", queryParameters)
		end

		def self.create_user(userRepresentation)
			generic_post("users/", nil, userRepresentation)
		end

		def self.count_users
			generic_get("users/count/")
		end

		def self.get_user(id)
			generic_get("users/#{id}")
		end

		def self.update_user(id, userRepresentation)
			generic_put("users/#{id}", nil, userRepresentation)
		end

		def self.delete_user(id)
			generic_delete("users/#{id}")
		end

		def self.revoke_consent_user(id, clientID = nil)
			if clientID.nil?
				clientID = Keycloak::Client.client_id
			end
			generic_delete("users/#{id}/consents/#{clientID}")
		end

		def self.update_account_email(id, actions, redirectUri = '', clientID = nil)
			if clientID.nil?
				clientID = Keycloak::Client.client_id
			end
			generic_put("users/#{id}/execute-actions-email", {:redirect_uri => redirectUri, :client_id => clientID}, actions)
		end

		def self.get_role_mappings(id)
			generic_get("users/#{id}/role-mappings")
		end

		def self.get_clients(queryParameters = nil)
			generic_get("clients/", queryParameters)
		end

		def self.get_all_roles_client(id)
			generic_get("clients/#{id}/roles")
		end

		def self.get_roles_client_by_name(id, roleName)
			generic_get("clients/#{id}/roles/#{roleName}")
		end

		def self.add_client_level_roles_to_user(id, client, roleRepresentation)
			generic_post("users/#{id}/role-mappings/clients/#{client}", nil, roleRepresentation)
		end

		def self.delete_client_level_roles_fom_user(id, client, roleRepresentation)
			generic_delete("users/#{id}/role-mappings/clients/#{client}", nil, roleRepresentation)
		end

		def self.get_client_level_role_for_user_and_app(id, client)
			generic_get("users/#{id}/role-mappings/clients/#{client}")
		end

		def self.update_effective_user_roles(id, clientID, rolesNames)
			client = JSON get_clients({:clientId => clientID})

			userRoles = JSON get_client_level_role_for_user_and_app(id, client[0]['id'])

			roles = Array.new
			# Include new role
			rolesNames.each do |r|
				if r && !r.empty?
					found = false
					userRoles.each do |ur|
						found = ur['name'] == r
						break if found
						found = false
					end
					if !found
						role = JSON get_roles_client_by_name(client[0]['id'], r)
						roles.push(role)
					end
				end
			end

			garbageRoles = Array.new
			# Exclude old role
			userRoles.each do |ur|
				found = false
				rolesNames.each do |r|
					if r && !r.empty?
						found = ur['name'] == r
						break if found
						found = false
					end
				end
				if !found
					garbageRoles.push(ur)
				end
			end

			if garbageRoles.count > 0
				delete_client_level_roles_fom_user(id, client[0]['id'], garbageRoles)
			end

			if roles.count > 0
				add_client_level_roles_to_user(id, client[0]['id'], roles)
			end
		end

		def self.reset_password(id, credentialRepresentation)
			generic_put("users/#{id}/reset-password", nil, credentialRepresentation)
		end

		# Generics methods

		def self.generic_get(service, queryParameters = nil)
			Keycloak.generic_request(Keycloak::Client.token['access_token'], full_url(service), queryParameters, nil, 'GET')
		end

		def self.generic_post(service, queryParameters, bodyParameter)
			Keycloak.generic_request(Keycloak::Client.token['access_token'], full_url(service), queryParameters, bodyParameter, 'POST')
		end

		def self.generic_put(service, queryParameters, bodyParameter)
			Keycloak.generic_request(Keycloak::Client.token['access_token'], full_url(service), queryParameters, bodyParameter, 'PUT')
		end

		def self.generic_delete(service, queryParameters = nil, bodyParameter = nil)
			Keycloak.generic_request(Keycloak::Client.token['access_token'], full_url(service), queryParameters, bodyParameter, 'DELETE')
		end

		private

			def self.base_url
				Keycloak::Client.auth_server_url + "/admin/realms/#{Keycloak::Client.realm}/"
			end

			def self.full_url(service)
				base_url + service
			end

	end

	module Internal
		include Keycloak::Admin

		class << self
			attr_accessor
		end

		def self.change_password(userID, redirectURI = '')
			proc = lambda {|token|
				Keycloak.generic_request(token["access_token"],
										 Keycloak::Admin.full_url("users/#{userID}/execute-actions-email"),
										 {:redirect_uri => redirectURI, :client_id => Keycloak::Client.client_id},
										 ['UPDATE_PASSWORD'],
										 'PUT')
			}

			default_call(proc)
		end

		def self.forgot_password(userLogin, redirectURI = '')
			user = get_user_info(userLogin, true)
			change_password(user['id'], redirectURI)
		end

		def self.get_logged_user_info
			proc = lambda {|token|
			    userinfo = JSON Keycloak::Client.get_userinfo
				Keycloak.generic_request(token["access_token"],
							             Keycloak::Admin.full_url("users/#{userinfo['sub']}"),
										 nil, nil, 'GET')
			}

			default_call(proc)
		end

		def self.get_user_info(userLogin, wholeWord = false)
			proc = lambda {|token|
				if userLogin.index('@').nil?
					search = {:username => userLogin}
				else
					search = {:email => userLogin}
				end
				users = JSON Keycloak.generic_request(token["access_token"],
						      	    			      Keycloak::Admin.full_url("users/"),
													  search, nil, 'GET')
				users[0]
				if users.count == 0
					raise Keycloak::UserLoginNotFound
				else
					efectiveIndex = -1
					users.each_with_index do |user, i|
						if wholeWord
							efectiveIndex = i if userLogin == user['username'] || userLogin == user['email']
						else
							efectiveIndex = 0
						end
						break if efectiveIndex >= 0
					end

					if efectiveIndex >= 0
						if wholeWord
							users[efectiveIndex]
						else
							users
						end
					else
						raise Keycloak::UserLoginNotFound
					end
				end
			}

			default_call(proc)
		end

		def self.is_logged_federation_user?
			info = get_logged_user_info
			info['federationLink'] != nil
		end

		def self.create_starter_user(userName, password, email, clientRolesNames, proc = nil)
			begin
				user = get_user_info(userName, true)
				newUser = false
			rescue Keycloak::UserLoginNotFound
				newUser = true
			rescue
				raise
			end

			procDefault = lambda {|token|
				userRepresentation = {:username => userName,
										:email => email,
										:enabled => true}

				if !newUser || Keycloak.generic_request(token["access_token"],
														Keycloak::Admin.full_url("users/"),
														nil, userRepresentation, 'POST')

					user = get_user_info(userName, true) if newUser

					credentialRepresentation = {:type => "password",
												:temporary => false,
												:value => password}

					if Keycloak.generic_request(token["access_token"],
												Keycloak::Admin.full_url("users/#{user['id']}/reset-password"),
												nil, credentialRepresentation, 'PUT')

						client = JSON Keycloak.generic_request(token["access_token"],
															   Keycloak::Admin.full_url("clients/"),
						                                       {:clientId => Keycloak::Client.client_id}, nil, 'GET')

						roles = Array.new
						clientRolesNames.each do |r|
							if r && !r.empty?
								role = JSON Keycloak.generic_request(token["access_token"],
																		Keycloak::Admin.full_url("clients/#{client[0]['id']}/roles/#{r}"),
																		nil, nil, 'GET')
								roles.push(role)
							end
						end

						if roles.count > 0
							Keycloak.generic_request(token["access_token"],
													 Keycloak::Admin.full_url("users/#{user['id']}/role-mappings/clients/#{client[0]['id']}"),
													 nil, roles, 'POST')
						end
					end

				end
			}

			if default_call(procDefault)
				if !proc.nil?
					proc.call user
				end
			end

		end

		protected

			def self.default_call(proc)
				begin
					tk = nil
					resp = nil

					Keycloak::Client.get_installation

					payload = {'client_id' => Keycloak::Client.client_id,
							   'client_secret' => Keycloak::Client.secret,
							   'grant_type' => 'client_credentials'
							  }

					header = {'Content-Type' => 'application/x-www-form-urlencoded'}

					_request = -> do
						RestClient.post(Keycloak::Client.configuration['token_endpoint'], payload, header){|response, request, result|
							case response.code
							when 200..399
								tk = JSON response.body
								resp = proc.call(tk)
							else
								response.return!
							end
						}
					end

					Keycloak::Client.exec_request _request
				ensure
					if tk
						payload = {'client_id' => Keycloak::Client.client_id,
											'client_secret' => Keycloak::Client.secret,
											'refresh_token' => tk["refresh_token"]
											}

						header = {'Content-Type' => 'application/x-www-form-urlencoded'}
						_request = -> do
							RestClient.post(Keycloak::Client.configuration['end_session_endpoint'], payload, header){|response, request, result|
								case response.code
								when 200..399
									resp if resp.nil?
								else
									response.return!
								end
							}
						end
						Keycloak::Client.exec_request _request
					end
				end
			end

	end

	private

		def self.generic_request(accessToken, uri, queryParameters, bodyParameter, method)
			Keycloak::Client.verify_setup
			final_url = uri

			header = {'Content-Type' => 'application/x-www-form-urlencoded',
								'Authorization' => "Bearer #{accessToken}"}

			if queryParameters
				parameters = URI.encode_www_form(queryParameters)
				final_url = final_url << '?' << parameters
			end

			case method.upcase
			when 'GET'
				_request = -> do
					RestClient.get(final_url, header){|response, request, result|
						rescue_response(response)
					}
				end
			when 'POST', 'PUT'
				header["Content-Type"] = 'application/json'
				parameters = JSON.generate bodyParameter
				_request = -> do
					case method.upcase
					when 'POST'
						RestClient.post(final_url, parameters, header){|response, request, result|
							rescue_response(response)
						}
					else
						RestClient.put(final_url, parameters, header){|response, request, result|
							rescue_response(response)
						}
					end
				end
			when 'DELETE'
				_request = -> do
					if bodyParameter
						header["Content-Type"] = 'application/json'
						parameters = JSON.generate bodyParameter
						RestClient::Request.execute(method: :delete, url: final_url,
													payload: parameters, headers: header){|response, request, result|
							rescue_response(response)
						}
					else
						RestClient.delete(final_url, header){|response, request, result|
							rescue_response(response)
						}
					end
				end
			else
				raise
			end

			_request.call

		end

		def self.rescue_response(response)
			case response.code
			when 200..399
				if response.body.empty?
					true
				else
					response.body
				end
			else
				if Keycloak.explode_exception
					response.return!
				else
					begin
						response.return!
					rescue RestClient::ExceptionWithResponse => err
						err.response
					rescue Exception => e
						e.message
					end
				end
			end
		end

end

require 'keycloak/exceptions'