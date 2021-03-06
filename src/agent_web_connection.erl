%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at fusedsolutions dot com>
%%

%% @doc Handles the internal (cpx interaction) part of an agent web connection.
%% (2008 12 09 : marking this for a refactoring.  Micah)
%% @see agent_web_listener
-module(agent_web_connection).
-author("Micah").

-behaviour(gen_server).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(TICK_LENGTH, 11000).

-include("log.hrl").
-include("call.hrl").
-include("agent.hrl").
-include("queue.hrl").

-include_lib("stdlib/include/qlc.hrl").

%% API
-export([
	start_link/2,
	start/2,
	stop/1,
	api/2,
	dump_agent/1,
	encode_statedata/1,
	set_salt/2,
	poll/2,
	keep_alive/1,
	mediaload/1,
	dump_state/1,
	format_status/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-type(tref() :: any()).

-record(state, {
	salt :: any(),
	agent_fsm :: pid() | 'undefined',
	current_call :: #call{} | 'undefined' | 'expect',
	mediaload :: any(),
	poll_queue = [] :: [{struct, [{binary(), any()}]}],
		% list of json structs to be sent to the client on poll.
	poll_pid :: 'undefined' | pid(),
	poll_pid_established = 1 :: pos_integer(),
	ack_timer :: tref() | 'undefined',
	securitylevel = agent :: 'agent' | 'supervisor' | 'admin',
	listener :: 'undefined' | pid()
}).

-type(state() :: #state{}).
-define(GEN_SERVER, true).
-include("gen_spec.hrl").

-type(json_simple() :: {'struct', [{binary(), binary()}]}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Description: Starts the server
%%--------------------------------------------------------------------

%% @doc Starts the passed agent at the given security level.
-spec(start_link/2 :: (Agent :: #agent{}, Security :: security_level()) -> {'ok', pid()} | 'ignore' | {'error', any()}).
start_link(Agent, Security) ->
	gen_server:start_link(?MODULE, [Agent, Security], [{timeout, 10000}]).

%% @doc Starts the passed agent at the given security level.
-spec(start/2 :: (Agent :: #agent{}, Security :: security_level()) -> {'ok', pid()} | 'ignore' | {'error', any()}).
start(Agent, Security) ->
	gen_server:start(?MODULE, [Agent, Security], [{timeout, 10000}]).

%% @doc Stops the passed Web connection process.
-spec(stop/1 :: (Pid :: pid()) -> 'ok').
stop(Pid) ->
	gen_server:call(Pid, stop).

%% @doc Register Frompid as the poll_pid.
-spec(poll/2 :: (Pid :: pid(), Frompid :: pid()) -> 'ok').
poll(Pid, Frompid) ->
	gen_server:cast(Pid, {poll, Frompid}).

%% @doc Do a web api call.
-spec(api/2 :: (Pid :: pid(), Apicall :: any()) -> any()).
api(Pid, Apicall) ->
	gen_server:call(Pid, Apicall).

%% @doc Dump the state of agent associated with the passed connection.
-spec(dump_agent/1 :: (Pid :: pid()) -> #agent{}).
dump_agent(Pid) ->
	gen_server:call(Pid, dump_agent).

%% @doc Sets the salt.  Hmmm, salt....
-spec(set_salt/2 :: (Pid :: pid(), Salt :: any()) -> 'ok').
set_salt(Pid, Salt) ->
	gen_server:cast(Pid, {set_salt, Salt}).

%% @doc keep alive, keep alive.
-spec(keep_alive/1 :: (Pid :: pid()) -> 'ok').
keep_alive(Pid) ->
	gen_server:cast(Pid, keep_alive).

%% @doc Get the settings used for a media load.  Only useful for the web
%% listener, and then only useful in the checkcookie clause.
-spec(mediaload/1 :: (Conn :: pid()) -> [{any(), any()}] | 'undefined').
mediaload(Conn) ->
	gen_server:call(Conn, mediaload).

dump_state(Conn) ->
	gen_server:call(Conn, dump_state).

%% @doc Encode the given data into a structure suitable for mochijson2:encode
-spec(encode_statedata/1 :: 
	(Callrec :: #call{}) -> json_simple();
	(Clientrec :: #client{}) -> json_simple();
	({'onhold', Holdcall :: #call{}, 'calling', any()}) -> json_simple();
	({Relcode :: string(), Bias :: non_neg_integer()}) -> json_simple();
	('default') -> {'struct', [{binary(), 'default'}]};
	(List :: string()) -> binary();
	({}) -> 'false').
encode_statedata(Callrec) when is_record(Callrec, call) ->
%	case Callrec#call.client of
%		Clientrec when is_record(Clientrec, client) ->
%			Brand = Clientrec#client.label;
%		_ ->
%			Brand = "unknown client"
%	end,
	Clientrec = Callrec#call.client,
	Client = case Clientrec#client.label of
		undefined ->
			<<"unknown client">>;
		Else ->
			list_to_binary(Else)
	end,
	{struct, [
		{<<"callerid">>, list_to_binary(element(1, Callrec#call.callerid) ++ " " ++ element(2, Callrec#call.callerid))},
		{<<"brandname">>, Client},
		{<<"ringpath">>, Callrec#call.ring_path},
		{<<"mediapath">>, Callrec#call.media_path},
		{<<"callid">>, list_to_binary(Callrec#call.id)},
		{<<"type">>, Callrec#call.type}]};
encode_statedata(Clientrec) when is_record(Clientrec, client) ->
	Label = case Clientrec#client.label of
		undefined ->
			undefined;
		Else ->
			list_to_binary(Else)
	end,
	{struct, [
		{<<"brandname">>, Label}]};
encode_statedata({onhold, Holdcall, calling, Calling}) ->
	Holdjson = encode_statedata(Holdcall),
	Callingjson = encode_statedata(Calling),
	{struct, [
		{<<"onhold">>, Holdjson},
		{<<"calling">>, Callingjson}]};
encode_statedata({_, default, _}) ->
	{struct, [{<<"reason">>, default}]};
encode_statedata({_, Reason, _}) ->
	{struct, [{<<"reason">>, list_to_binary(Reason)}]};
encode_statedata(List) when is_list(List) ->
	list_to_binary(List);
encode_statedata({}) ->
	false.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Agent, Security]) ->
	?DEBUG("web_connection init ~p with security ~w", [Agent, Security]),
	process_flag(trap_exit, true),
	case agent_manager:start_agent(Agent) of
		{ok, Apid} ->
			ok;
		{exists, Apid} ->
			ok
	end,
	case agent:set_connection(Apid, self()) of
		error ->
			{stop, "Agent is already logged in"};
		_Else ->
			Tref = erlang:send_after(?TICK_LENGTH, self(), check_live_poll),
			agent_web_listener:linkto(self()),
			State = agent:dump_state(Apid),
			CurrentCall = case State#agent.statedata of
				Call when is_record(Call, call) ->
					Call;
				{on_hold, Call, calling, _Number} ->
					Call;
				_ ->
					undefined
			end,

%			case Security of
%				agent ->
%					ok;
%				supervisor ->
%					cpx_monitor:subscribe();
%				admin ->
%					cpx_monitor:subscribe()
%			end,
			{ok, #state{agent_fsm = Apid, current_call = CurrentCall, ack_timer = Tref, securitylevel = Security, listener = whereis(agent_web_listener)}}
	end.

%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
	{stop, shutdown, ok, State};
handle_call(logout, _From, State) ->
	{stop, normal, {200, [{"Set-Cookie", "cpx_id=dead"}], mochijson2:encode({struct, [{success, true}]})}, State};
handle_call(get_avail_agents, _From, State) ->
	Agents = [AgState || {_K, {Pid, _Id, _Time, _Skills}} <-
		agent_manager:list(),
		AgState <- [agent:dump_state(Pid)],
		AgState#agent.state == idle orelse AgState#agent.state == released],

	Noms = [{struct, [{<<"name">>, list_to_binary(Rec#agent.login)}, {<<"profile">>, list_to_binary(Rec#agent.profile)}, {<<"state">>, Rec#agent.state}]} || Rec <- Agents],
	{reply, {200, [], mochijson2:encode({struct, [{success, true}, {<<"agents">>, Noms}]})}, State};
handle_call({set_state, Statename}, _From, #state{agent_fsm = Apid} = State) ->
	case agent:set_state(Apid, agent:list_to_state(Statename)) of
		ok ->
			{reply, {200, [], mochijson2:encode({struct, [{success, true}, {<<"status">>, ok}]})}, State};
		invalid ->
			{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"status">>, invalid}]})}, State}
	end;
handle_call({set_state, Statename, InStatedata}, _From, #state{agent_fsm = Apid} = State) ->
	Statedata = case Statename of
		"released" ->
			case InStatedata of
				"Default" ->
					default;
				_ ->
					[Id, Name, Bias] = util:string_split(InStatedata, ":"),
					{Id, Name, list_to_integer(Bias)}
			end;
		_ ->
			InStatedata
	end,
	case agent:set_state(Apid, agent:list_to_state(Statename), Statedata) of
		invalid ->
			{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"status">>, invalid}]})}, State};
		Status ->
			{reply, {200, [], mochijson2:encode({struct, [{success, true}, {<<"status">>, Status}]})}, State}
	end;
handle_call({set_endpoint, Endpoint}, _From, #state{agent_fsm = Apid} = State) ->
	{reply, agent:set_endpoint(Apid, Endpoint), State};
handle_call({dial, Number}, _From, #state{agent_fsm = AgentPid} = State) ->
	AgentRec = agent:dump_state(AgentPid),
	case AgentRec#agent.state of
		precall ->
			#agent{statedata = Call} = AgentRec,
			case Call#call.direction of
				outbound ->
					case gen_media:call(Call#call.source, {dial, Number}) of
						ok ->
							{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State};
						{error, Error} ->
							?NOTICE("Outbound call error ~p", [Error]),
							{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, list_to_binary(lists:flatten(io_lib:format("~p, Check your phone configuration", [Error])))}]})}, State}
					end;
				_ ->
					{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"This is not an outbound call">>}]})}, State}
			end;
		_ ->
			{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Agent is not in pre-call">>}]})}, State}
	end;
handle_call(dump_agent, _From, #state{agent_fsm = Apid} = State) ->
	Astate = agent:dump_state(Apid),
	{reply, Astate, State};
handle_call({agent_transfer, Agentname, CaseID}, From, #state{current_call = Call} = State) when is_record(Call, call) ->
	gen_media:cast(Call#call.source, {set_caseid, CaseID}),
	handle_call({agent_transfer, Agentname}, From, State);
handle_call({agent_transfer, Agentname}, _From, #state{agent_fsm = Apid} = State) ->
	case agent_manager:query_agent(Agentname) of
		{true, Target} ->
			Reply = case agent:agent_transfer(Apid, Target) of
				ok ->
					{200, [], mochijson2:encode({struct, [{success, true}]})};
				invalid ->
					{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Could not start transfer">>}]})}
			end,
			{reply, Reply, State};
		false ->
			{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Agent not found">>}]})}, State}
	end;
handle_call({warm_transfer, Number}, _From, #state{current_call = Call} = State) when is_record(Call, call) ->
	?NOTICE("warm transfer to ~p", [Number]),
	Reply = case gen_media:warm_transfer_begin(Call#call.source, Number) of
		ok ->
			{200, [], mochijson2:encode({struct, [{success, true}]})};
		invalid ->
			{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Could not start transfer">>}]})}
	end,
	{reply, Reply, State};
handle_call(warm_transfer_cancel, _From, #state{current_call = Call} = State) when is_record(Call, call) ->
	?NOTICE("warm transfer cancel", []),
	Reply = case gen_media:warm_transfer_cancel(Call#call.source) of
		ok ->
			{200, [], mochijson2:encode({struct, [{success, true}]})};
		invalid ->
			{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Could not cancel transfer">>}]})}
	end,
	{reply, Reply, State};
handle_call(warm_transfer_complete, _From, #state{current_call = Call} = State) when is_record(Call, call) ->
	?NOTICE("warm transfer complete", []),
	Reply = case gen_media:warm_transfer_complete(Call#call.source) of
		ok ->
			{200, [], mochijson2:encode({struct, [{success, true}]})};
		invalid ->
			{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Could not complete transfer">>}]})}
	end,
	{reply, Reply, State};
handle_call({init_outbound, Client, Type}, _From, #state{agent_fsm = Apid} = State) ->
	?NOTICE("Request to initiate outbound call of type ~p to ~p", [Type, Client]),
	AgentRec = agent:dump_state(Apid), % TODO - avoid
	Reply = case AgentRec#agent.state of
		Agentstate when Agentstate =:= released; Agentstate =:= idle ->
			try list_to_existing_atom(Type) of
				freeswitch ->
					case whereis(freeswitch_media_manager) of
						P when is_pid(P) ->
							case freeswitch_media_manager:make_outbound_call(Client, Apid, AgentRec#agent.login) of
								{ok, Pid} ->
									Call = gen_media:get_call(Pid),
									agent:set_state(Apid, precall, Call),
									{200, [], mochijson2:encode({struct, [{success, true}]})};
								{error, Reason} ->
									{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, list_to_binary(io_lib:format("Initializing outbound call failed (~p)", [Reason]))}]})}
							end;
						_ ->
							{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"freeswitch is not available">>}]})}
					end;
				% TODO - more outbound types go here :)
				_ ->
					{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Unknown call type">>}]})}
			catch
				_:_ ->
					{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Unknown call type">>}]})}
			end;
		_ ->
			{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Agent must be released or idle">>}]})}
	end,
	{reply, Reply, State};
handle_call({{supervisor, Request}, Post}, _From, #state{securitylevel = Seclevel} = State) when Seclevel =:= supervisor; Seclevel =:= admin ->
	?DEBUG("Supervisor request with post data:  ~s", [lists:flatten(Request)]),
	case Request of
		["set_profile"] ->
			Login = proplists:get_value("name", Post),
			%Id = proplists:get_value("id", Post),
			Newprof = proplists:get_value("profile", Post),
			Midgood = case agent_manager:query_agent(Login) of
				{true, Apid} ->
					agent:change_profile(Apid, Newprof);
				false ->
					{error, noagent}
			end,
			case {Midgood, proplists:get_value("makePerm", Post)} of
				{{error, Err}, _} ->
					Msg = case Err of
						noagent ->
							<<"unknown agent">>;
						unknown_profile ->
							<<"unknown profile">>%;
%						_ ->
%							list_to_binary(io_lib:format("~p", [Err]))
					end,
					{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, Msg}]})}, State};
				{ok, "makePerm"} ->
					case agent_auth:get_agent(login, Login) of
						{atomic, [Arec]} ->
							case agent_auth:set_agent(Arec#agent_auth.id, Login, Arec#agent_auth.skills, Arec#agent_auth.securitylevel, Newprof) of
								{atomic, ok} ->
									{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State};
								{aborted, Err} ->
									Msg = list_to_binary(io_lib:format("Profile changed, but not permanent:  ~p", [Err])),
									{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, Msg}]})}, State}
							end;
						{atomic, []} ->
							{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Agent is not permantent, so not permanent change made">>}]})}, State}
					end;
				{ok, _} ->
					{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State}
			end;
		["blab"] ->
			Toagentmanager = case proplists:get_value("type", Post) of
				"agent" ->
					{agent, proplists:get_value("value", Post, "")};
				"node" ->
					case proplists:get_value("value", Post) of
						"System" ->
							all;
						_AtomIsIt -> 
							try list_to_existing_atom(proplists:get_value("value", Post)) of
								Atom ->
									case lists:member(Atom, [node() | nodes()]) of
										true ->
											{node, Atom};
										false ->
											{false, false}
									end
							catch
								error:badarg ->
									{false, false}
							end
					end;
				"profile" ->
					{profile, proplists:get_value("value", Post, "")};
				"all" ->
					all
			end,
			Json = case Toagentmanager of
				{false, false} ->
					mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"bad type or value">>}]});
				Else ->
					agent_manager:blab(proplists:get_value("message", Post, ""), Else),
					mochijson2:encode({struct, [{success, true}, {<<"message">>, <<"blabbing">>}]})
			end,
			{reply, {200, [], Json}, State};
		["motd"] ->
			{ok, Appnodes} = application:get_env(cpx, nodes),
			Nodes = case proplists:get_value("node", Post) of
				"system" ->
					Appnodes;
				Postnode ->
					case lists:any(fun(N) -> atom_to_list(N) == Postnode end, Appnodes) of
						true ->
							[list_to_existing_atom(Postnode)];
						false ->
							[]
					end
			end,
			case Nodes of
				[] ->
					{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"no known nodes">>}]})}, State};
				_ ->
					Fun = case proplists:get_value("message", Post) of
						"" ->
							fun(Node) ->
								try rpc:call(Node, cpx_supervisor, drop_value, [motd]) of
									{atomic, ok} ->
										ok
								catch
									_:_ ->
										?WARNING("Could not set motd on ~p", [Node])
								end
							end;
						Message ->
							fun(Node) ->
								try rpc:call(Node, cpx_supervisor, set_value, [motd, Message]) of
									{atomic, ok} ->
										ok
								catch
									_:_ ->
										?WARNING("Count not set motd on ~p", [Node])
								end
							end
					end,
					lists:foreach(Fun, Nodes),
					{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State}
			end
	end;
handle_call({supervisor, Request}, _From, #state{securitylevel = Seclevel} = State) when Seclevel =:= supervisor; Seclevel =:= admin ->
	?DEBUG("Handing supervisor request ~s", [lists:flatten(Request)]),
	case Request of
		["startmonitor"] ->
			cpx_monitor:subscribe(),
			{reply, {200, [], mochijson2:encode({struct, [{success, true}, {<<"message">>, <<"subscribed">>}]})}, State};
		["start_problem_recording", _Agentname, Clientid] ->
			AgentRec = agent:dump_state(State#state.agent_fsm), % TODO - avoid
			case whereis(freeswitch_media_manager) of
				P when is_pid(P) ->
					case freeswitch_media_manager:record_outage(Clientid, State#state.agent_fsm, AgentRec#agent.login) of
						ok ->
							{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State};
						{error, Reason} ->
							{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, list_to_binary(io_lib:format("Initializing recording channel failed (~p)", [Reason]))}]})}, State}
					end;
				_ ->
					{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"freeswitch is not available">>}]})}, State}
			end;
		["remove_problem_recording", Clientid] ->
			case file:delete("/tmp/"++Clientid++"/problem.wav") of
				ok ->
					{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State};
				{error, Reason} ->
					{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, Reason}]})}, State}
			end;
		["voicemail", Queue, Callid] ->
			Json = case queue_manager:get_queue(Queue) of
				Qpid when is_pid(Qpid) ->
					case call_queue:get_call(Qpid, Callid) of
						{_Key, #queued_call{media = Mpid}} ->
							case gen_media:voicemail(Mpid) of
								invalid ->
									{struct, [{success, false}, {<<"message">>, <<"media doesn't support voicemail">>}]};
								ok ->
									{struct, [{success, true}]}
							end;
						_ ->
							{struct, [{success, false}, {<<"message">>, <<"call not found">>}]}
					end;
				_ ->
					{struct, [{success, false}, {<<"message">>, <<"queue not found">>}]}
			end,
			{reply, {200, [], mochijson2:encode(Json)}, State};
		["set_profile", Agent, Profile] ->
			case agent_manager:query_agent(Agent) of
				{true, Apid} ->
					case agent:change_profile(Apid, Profile) of
						ok ->
							{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State};
						{error, unknown_profile} ->
							{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"unknown_profile">>}]})}, State}
					end;
				false ->
					{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"unknown agent">>}]})}, State}
			end;
		["get_profiles"] ->
			Profiles = agent_auth:get_profiles(),
			F = fun(#agent_profile{name = Nom}) ->
				list_to_binary(Nom)
			end,
			{reply, {200, [], mochijson2:encode({struct, [{success, true}, {<<"profiles">>, lists:map(F, Profiles)}]})}, State};
		["endmonitor"] ->
			cpx_monitor:unsubscribe(),
			{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State};
		["spy", Agentname] ->
			Current = State#state.current_call,
			{Json, Newcurrent}  = case agent_manager:query_agent(Agentname) of
				{true, Apid} ->
					Mepid = State#state.agent_fsm,
					case agent:spy(Mepid, Apid) of
						ok ->
							{mochijson2:encode({struct, [{success, true}]}), expect};
						invalid ->
							{mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"invalid action">>}]}), Current}
					end;
				false ->
					{mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"no such agent">>}]}), Current}
			end,
			{reply, {200, [], Json}, State#state{current_call = Newcurrent}};
		["agentstate" | [Agent | Tail]] ->
			Json = case agent_manager:query_agent(Agent) of
				{true, Apid} ->
					%?DEBUG("Tail:  ~p", [Tail]),
					Statechange = case Tail of
						["released", "default"] ->
							agent:set_state(Apid, released, default);
						[Statename, Statedata] ->
							Astate = agent:list_to_state(Statename),
							agent:set_state(Apid, Astate, Statedata);
						[Statename] ->
							Astate = agent:list_to_state(Statename),
							agent:set_state(Apid, Astate)
					end,
					case Statechange of
						invalid ->
							mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"invalid state change">>}]});
						ok ->
							mochijson2:encode({struct, [{success, true}, {<<"message">>, <<"agent state set">>}]});
						queued ->
							mochijson2:encode({struct, [{success, true}, {<<"message">>, <<"agent release queued">>}]})
					end;
				_Else ->
					mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Agent not found">>}]})
			end,
			{reply, {200, [], Json}, State};
		["kick_agent", Agent] ->
			Json = case agent_manager:query_agent(Agent) of
				{true, Apid} ->
					case agent:query_state(Apid) of
						{ok, oncall} ->
							mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Agent currently oncall">>}]});
						{ok, _State} ->
							agent:stop(Apid),
							mochijson2:encode({struct, [{success, true}]})
					end;
				_Else ->
					mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Agent not found">>}]})
			end,
			{reply, {200, [], Json}, State};
		["requeue", Fromagent, Toqueue] ->
			Json = case agent_manager:query_agent(Fromagent) of
				{true, Apid} ->
					case agent:get_media(Apid) of
						invalid ->
							mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Agent isn't in call">>}]});
						{ok, #call{source = Mpid} = _Mediarec} ->
							case gen_media:queue(Mpid, Toqueue) of
								invalid ->
									mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Media said it couldn't be queued">>}]});
								ok ->
									mochijson2:encode({struct, [{success, true}]})
							end
					end;
				_Whatever ->
					mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Agent doesn't exists">>}]})
			end,
			{reply, {200, [], Json}, State};
		["agent_transfer", Fromagent, Toagent] ->
			Json = case {agent_manager:query_agent(Fromagent), agent_manager:query_agent(Toagent)} of
				{false, false} ->
					mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Agents don't exist">>}]});
				{{true, From}, {true, To}} ->
					agent:agent_transfer(From, To),
					mochijson2:encode({struct, [{success, true}, {<<"message">>, <<"Transfer beginning">>}]});
				{false, _} ->
					mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"From agent doesn't exist.">>}]});
				{_, false} ->
					mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"To agent doesn't exist.">>}]})
			end,
			{reply, {200, [], Json}, State};
		["agent_ring", Fromqueue, Callid, Toagent] ->
			Json = case {agent_manager:query_agent(Toagent), queue_manager:get_queue(Fromqueue)} of
				{false, undefined} ->
					mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Neither agent nor queue exist">>}]});
				{false, _Pid} ->
					mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"agent doesn't exist">>}]});
				{_Worked, undefined} ->
					mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"queue doesn't exist">>}]});
				{{true, Apid}, Qpid} ->
					case call_queue:get_call(Qpid, Callid) of
						none ->
							mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Call is not in the given queue">>}]});
						{_Key, #queued_call{media = Mpid} = Qcall} ->
							case gen_media:ring(Mpid, Apid, Qcall, 30000) of
								deferred ->
									mochijson2:encode({struct, [{success, true}]});
								 _ ->
									mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Could not ring agent">>}]})
							end
					end
			end,
			{reply, {200, [], Json}, State};
		["status"] ->
			% nodes, agents, queues, media, and system.
			cpx_monitor:subscribe(),
			{ok, Nodestats} = cpx_monitor:get_health(node),
			{ok, Agentstats} = cpx_monitor:get_health(agent),
			{ok, Queuestats} = cpx_monitor:get_health(queue),
			{ok, Systemstats} = cpx_monitor:get_health(system),
			{ok, Mediastats} = cpx_monitor:get_health(media),
			Groupstats = extract_groups(lists:append(Queuestats, Agentstats)),
			Stats = lists:append([Nodestats, Agentstats, Queuestats, Systemstats, Mediastats]),
			{Count, Encodedstats} = encode_stats(Stats),
			{_Count2, Encodedgroups} = encode_groups(Groupstats, Count),
			Encoded = lists:append(Encodedstats, Encodedgroups),
			Systemjson = {struct, [
				{<<"id">>, <<"system-System">>},
				{<<"type">>, <<"system">>},
				{<<"display">>, <<"System">>},
				{<<"health">>, {struct, [{<<"_type">>, <<"details">>}, {<<"_value">>, {struct, []}}]}},
				{<<"details">>, {struct, [{<<"_type">>, <<"details">>}, {<<"_value">>, {struct, []}}]}}
			]},
			Json = mochijson2:encode({struct, [
				{success, true},
				{<<"data">>, {struct, [
					{<<"identifier">>, <<"id">>},
					{<<"label">>, <<"display">>},
					{<<"items">>, [Systemjson | Encoded]}
				]}}
			]}),
			{reply, {200, [], Json}, State};
		
		
%			case file:read_file_info("sup_test_data.js") of
%				{error, Error} ->
%					?WARNING("Couldn't get test data due to ~p", [Error]),
%					{reply, {500, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Could not get data">>}]})}, State};
%				_Else ->
%					{ok, Io} = file:open("sup_test_data.js", [raw, binary]),
%					Read = fun(F, Acc) ->
%						case file:read(Io, 20) of
%							{ok, Data} ->
%								F(F, [Data | Acc]);
%							eof ->
%								lists:flatten(lists:reverse(Acc));
%							{error, Err} ->
%								Err
%						end
%					end,
%					Data = Read(Read, []),
%					file:close(Io),
%					{reply, {200, [], Data}, State}
%			end;
		["nodes"] ->
			Nodes = lists:sort([node() | nodes()]),
			F = fun(I) ->
				list_to_binary(atom_to_list(I))
			end,
			{reply, {200, [], mochijson2:encode({struct, [{success, true}, {<<"nodes">>, lists:map(F, Nodes)}]})}, State};
		["peek", Queue, Callid] ->
			{UnencodedJson, Newstate} = case agent:dump_state(State#state.agent_fsm) of
				#agent{state = released} ->
					case queue_manager:get_queue(Queue) of
						Qpid when is_pid(Qpid) ->
							case call_queue:get_call(Qpid, Callid) of
								none ->
									{{struct, [{success, false}, {<<"message">>, <<"Call not queued">>}]}, State};
								{_Key, #queued_call{media = Mpid}} ->
									case gen_media:call(Mpid, {peek, State#state.agent_fsm}) of
										ok ->
											{{struct, [{success, true}]}, State#state{current_call = expect}};
										_ ->
											{{struct, [{success, false}, {<<"message">>, <<"media didn't peek">>}]}, State}
									end
							end;
						_ ->
							{{struct, [{success, false}, {<<"message">>, <<"Queue doesn't exist">>}]}, State}
					end;
				_ ->
					{{struct, [{success, false}, {<<"message">>, <<"Can only peek while released">>}]}, State}
			end,
			{reply, {200, [], mochijson2:encode(UnencodedJson)}, Newstate};
		["drop_call", Queue, Callid] ->
			Json = case queue_manager:get_queue(Queue) of
				undefined ->
					{struct, [{success, false}, {<<"message">>, <<"queue not found">>}]};
				Qpid when is_pid(Qpid) ->
					case call_queue:get_call(Qpid, Callid) of
						none ->
							{struct, [{success, false}, {<<"message">>, <<"call not found">>}]};
						{_, #queued_call{media = _Mpid}} ->
							%%gen_media:cast(Mpid, email_drop), % only email should respond to this
							% TODO finish this when hangup can take a reason.
							{struct, [{success, false}, {<<"message">>, <<"nyi">>}]}
					end
			end,
			{reply, {200, [], mochijson2:encode(Json)}, State};
		["getmotd"] ->
			Motd = case cpx_supervisor:get_value(motd) of
				none ->
					false;
				{ok, Text} ->
					list_to_binary(Text)
			end,
			{reply, {200, [], mochijson2:encode({struct, [{success, true}, {motd, Motd}]})}, State};
		[Node | Do] ->
			Nodes = get_nodes(Node),
			{Success, Result} = do_action(Nodes, Do, []),
			{reply, {200, [], mochijson2:encode({struct, [{success, Success}, {<<"result">>, Result}]})}, State}
	end;
handle_call({supervisor, _Request}, _From, State) ->
	?NOTICE("Unauthorized access to a supervisor web call", []),
	{reply, {403, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"insufficient privledges">>}]})}, State};
handle_call({media, Post}, _From, #state{current_call = Call} = State) when is_record(Call, call) ->
	Commande = proplists:get_value("command", Post),
	?DEBUG("Media Command:  ~p", [Commande]),
	case proplists:get_value("mode", Post) of
		"call" ->
			{Heads, Data} = try gen_media:call(Call#call.source, {Commande, Post}) of
				invalid ->
					?DEBUG("agent:media_call returned invalid", []),
					{[], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"invalid media call">>}]})};
				Response ->
					parse_media_call(Call, {Commande, Post}, Response)
			catch
				exit:{noproc, _} ->
					?DEBUG("Media no longer exists.", []),
					{[], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"media no longer exists">>}]})}
			end,
			{reply, {200, Heads, Data}, State};
		"cast" ->
			gen_media:cast(Call#call.source, {Commande, Post}),
			{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State};
		undefined ->
			{reply, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"no mode defined">>}]})}, State}
	end;
handle_call({undefined, "/get_queue_transfer_options"}, _From, #state{current_call = Call} = State) when is_record(Call, call) ->
	{ok, Setvars} = gen_media:get_url_getvars(Call#call.source),
	{ok, {Prompts, Skills}} = cpx_supervisor:get_value(transferprompt),
	Varslist = [begin
		Newkey = case is_list(Key) of
			true ->
				list_to_binary(Key);
			_ ->
				Key
		end,
		Newval = case is_list(Val) of
			true ->
				list_to_binary(Val);
			_ ->
				Val
		end,
		{Newkey, Newval}
	end || 
	{Key, Val} <- Setvars],
	Encodedprompts = [{struct, [{<<"name">>, Name}, {<<"label">>, Label}, {<<"regex">>, Regex}]} || {Name, Label, Regex} <- Prompts],
	Encodedskills = cpx_web_management:encode_skills(Skills),
	Json = {struct, [
		{<<"success">>, true},
		{<<"currentVars">>, {struct, Varslist}},
		{<<"prompts">>, Encodedprompts},
		{<<"skills">>, Encodedskills}
	]},
	{reply, {200, [], mochijson2:encode(Json)}, State};
handle_call({undefined, "/call_hangup"}, _From, #state{current_call = Call} = State) when is_record(Call, call) ->
	Call#call.source ! call_hangup,
	Json = case agent:set_state(State#state.agent_fsm, {wrapup, State#state.current_call}) of
		invalid ->
			{struct, [{success, false}, {<<"message">>, <<"agent refused statechange">>}]};
		ok ->
			{struct, [{success, true}, {<<"message">>, <<"agent accepted statechange">>}]}
	end,
	{reply, {200, [], mochijson2:encode(Json)}, State};
handle_call({undefined, "/ringtest"}, _From, #state{current_call = undefined, agent_fsm = Apid} = State) ->
	AgentRec = agent:dump_state(Apid), % TODO - avoid
	Json = case whereis(freeswitch_media_manager) of
		Pid when is_pid(Pid), AgentRec#agent.state == released ->
			Callrec = #call{id="unused", source=self(), callerid={"Echo Test", "0000000"}},
			case freeswitch_media_manager:ring_agent_echo(Apid, AgentRec#agent.login, Callrec, 600) of
				{ok, _} ->
					{struct, [{success, true}]};
				{error, Error} ->
					{struct, [{success, false}, {<<"message">>, iolist_to_binary(io_lib:format("ring test failed: ~p", [Error]))}]}
			end;
		undefined ->
			{struct, [{success, false}, {<<"message">>, <<"freeswitch is not available">>}]};
		_ ->
			{struct, [{success, false}, {<<"message">>, <<"you must be released to perform a ring test">>}]}
	end,
	{reply, {200, [], mochijson2:encode(Json)}, State};
handle_call({undefined, "/queue_transfer", Opts}, From, #state{current_call = Call, agent_fsm = Apid} = State) when is_record(Call, call) ->
	Queue = proplists:get_value("queue", Opts),
	MidSkills = proplists:get_all_values("skills", Opts),
	Midopts = proplists:delete("skills", proplists:delete("queue", Opts)),
	gen_media:set_url_getvars(Call#call.source, Midopts),
	Skills = cpx_web_management:parse_posted_skills(MidSkills),
	gen_media:add_skills(Call#call.source, Skills),
	?NOTICE("queue transfer to ~p", [Queue]),
	?DEBUG("options:  ~p", [Opts]),
	Reply = case agent:queue_transfer(Apid, Queue) of
		ok ->
			{200, [], mochijson2:encode({struct, [{success, true}]})};
		invalid ->
			{200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Could not start transfer">>}]})}
	end,
	{reply, Reply, State};
handle_call({undefined, "/report_issue", Post}, _From, State) ->
	Summary = proplists:get_value("reportIssueSummary", Post),
	Description = proplists:get_value("reportIssueError", Post),
	Reproduce = proplists:get_value("reportIssueReproduce", Post),
	Humandetails = proplists:get_value("reportIssueDetails", Post),
	Uidetails = proplists:get_value("uistate", Post),
	Details = list_to_binary([Humandetails, <<"\n==== automatically gathered ====\n">>, Uidetails]),
	case cpx_supervisor:submit_bug_report(list_to_binary(Summary), list_to_binary(Description), list_to_binary(Reproduce), Details) of
		ok ->
			{reply, {200, [], mochijson2:encode({struct, [{success, true}]})}, State};
		{error, Err} ->
			Json = {struct, [
				{success, false},
				{<<"message">>, list_to_binary(io_lib:format("~p", [Err]))}
			]},
			{reply, {200, [], mochijson2:encode(Json)}, State}
	end;
handle_call({undefined, "/profilelist"}, _From, State) ->
	Profiles = agent_auth:get_profiles(),
	% TODO finish off the filtering.
%	#agent{profile = Myprof} = agent:dump_state(State#state.agent_fsm);
%	Filter = fun(#agent_profile{options = Opts} = Prof) ->
%		if
%			proplists:get_value(hidden, Opts) ->
%				false;
%			proplists:get_value(isolated, Opts, false) andalso (Prof#agent_profile.name =/= Myprof) ->
%				false;
	
	Jsons = [
		{struct, [{<<"name">>, list_to_binary(Name)}, {<<"order">>, Order}]} ||
		#agent_profile{name = Name, order = Order} <- Profiles
	],
	R = {200, [], mochijson2:encode({struct, [{success, true}, {<<"profiles">>, Jsons}]})},
	{reply, R, State};	
handle_call({undefined, [$/ | Path]}, From, State) ->
	handle_call({undefined, [$/ | Path], []}, From, State);
handle_call({undefined, [$/ | Path], Post}, _From, #state{current_call = Call} = State) when is_record(Call, call) ->
	%% considering how things have gone, the best guess is this is a media call.
	%% Note that the results below are only for email, so this will need
	%% to be refactored when we support more medias.
	?DEBUG("forwarding request to media.  Path: ~p; Post: ~p", [Path, Post]),
	try gen_media:call(Call#call.source, {get_blind, Path}) of
		{ok, Mime} ->
			{Heads, Data} = parse_media_call(Call, {"get_path", Path}, {ok, Mime}),
%			Body = element(5, Mime),
%			{reply, {200, [], list_to_binary(Body)}, State};
			{reply, {200, Heads, Data}, State};
		none ->
			{reply, {404, [], <<"path not found">>}, State};
		{message, Mime} ->
			Filename = case email_media:get_disposition(Mime) of
				inline ->
					util:bin_to_hexstr(erlang:md5(erlang:ref_to_list(make_ref())));
				{_, Nom} ->
					binary_to_list(Nom)
			end,
			Heads = [
				{"Content-Disposition", lists:flatten(io_lib:format("attachment; filename=\"~s\"", [Filename]))},
				{"Content-Type", lists:append([binary_to_list(element(1, Mime)), "/", binary_to_list(element(2, Mime))])}
			],
			Encoded = mimemail:encode(Mime),
			{reply, {200, Heads, Encoded}, State};
		Else ->
			?INFO("Not a mime tuple ~p", [Else]),
			{reply, {404, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"unparsable reply">>}]})}, State}
	catch
		exit:{noproc, _} ->
			?ERROR("request to fetch ~p from ~p ~p by ~p", [Path, Call#call.id, Call#call.source, State#state.agent_fsm]),
			{reply, {404, [], <<"path not found">>}, State}
	end;
handle_call(mediaload, _From, State) ->
	{reply, State#state.mediaload, State};
handle_call(dump_state, _From, State) ->
	{reply, State, State};
handle_call(Allothers, _From, State) ->
	?DEBUG("unknown call ~p", [Allothers]),
	{reply, {404, [], <<"unknown_call">>}, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(keep_alive, #state{poll_pid = undefined} = State) ->
	?DEBUG("keep alive", []),
	{noreply, State#state{poll_pid_established = util:now()}};
handle_cast({poll, Frompid}, State) ->
	%?DEBUG("Replacing poll_pid ~w with ~w", [State#state.poll_pid, Frompid]),
	case State#state.poll_pid of
		undefined -> 
			ok;
		Pid when is_pid(Pid) ->
			Pid ! {kill, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"Poll pid replaced">>}]})}
	end,
	case State#state.poll_queue of
		[] ->
			%?DEBUG("Empty poll queue", []),
			link(Frompid),
			{noreply, State#state{poll_pid = Frompid, poll_pid_established = util:now()}};
		Pollq ->
			%?DEBUG("Poll queue length: ~p", [length(Pollq)]),
			Newstate = State#state{poll_queue=[], poll_pid_established = util:now(), poll_pid = undefined},
			Json2 = {struct, [{success, true}, {message, <<"Poll successful">>}, {data, lists:reverse(Pollq)}]},
			Frompid ! {poll, {200, [], mochijson2:encode(Json2)}},
			{noreply, Newstate}
	end;
handle_cast({mediaload, #call{type = email} = Call}, State) ->
	Midstate = case State#state.current_call of
		expect ->
			State#state{current_call = Call};
		_ ->
			State
	end,
	Json = {struct, [
		{<<"command">>, <<"mediaload">>},
		{<<"media">>, <<"email">>}
	]},
	Newstate = push_event(Json, Midstate),
	{noreply, Newstate#state{mediaload = []}};
handle_cast({mediaload, #call{type = voice}}, State) ->
	Json = {struct, [
		{<<"command">>, <<"mediaload">>},
		{<<"media">>, <<"voice">>},
		{<<"fullpane">>, false}
	]},
	Newstate = push_event(Json, State),
	{noreply, Newstate#state{mediaload = [{<<"fullpane">>, false}]}};
handle_cast({mediaload, #call{type = voice}, Options}, State) ->
	Base = [
		{<<"command">>, <<"mediaload">>},
		{<<"media">>, <<"voice">>},
		{<<"fullpane">>, false}
	],
	Json = {struct, lists:append(Base, Options)},
	Newstate = push_event(Json, State),
	{noreply, Newstate#state{mediaload = [{<<"fullpane">>, false} | Options]}};
handle_cast({mediapush, #call{type = Mediatype}, Data}, State) ->
	?DEBUG("mediapush type:  ~p;  Data:  ~p", [Mediatype, Data]),
	case Mediatype of
		email ->
			case Data of
				send_done ->
					Json = {struct, [
						{<<"command">>, <<"mediaevent">>},
						{<<"media">>, email},
						{<<"event">>, <<"send_complete">>},
						{<<"success">>, true}
					]},
					Newstate = push_event(Json, State),
					{noreply, Newstate};
				{send_fail, Error} ->
					Json = {struct, [
						{<<"command">>, <<"mediaevent">>},
						{<<"media">>, email},
						{<<"event">>, <<"send_complete">>},
						{<<"message">>, list_to_binary(io_lib:format("~p", [Error]))},
						{<<"success">>, false}
					]},
					Newstate = push_event(Json, State),
					{noreply, Newstate};
				_Else ->
					?INFO("No other data's supported:  ~p", [Data]),
					{noreply, State}
			end;
		voice ->
			case Data of
				warm_transfer_succeeded ->
					Json = {struct, [
						{<<"command">>, <<"mediaevent">>},
						{<<"media">>, voice},
						{<<"event">>, Data},
						{success, true}
					]},
					Newstate = push_event(Json, State),
					{noreply, Newstate};
				warm_transfer_failed ->
					Json = {struct, [
						{<<"command">>, <<"mediaevent">>},
						{<<"media">>, voice},
						{<<"event">>, Data},
						{success, false}
					]},
					Newstate = push_event(Json, State),
					{noreply, Newstate}
			end;
		Else ->
			?INFO("Currently no for media pushings: ~p", [Else]),
			{noreply, State}
	end;
handle_cast({set_salt, Salt}, State) ->
	{noreply, State#state{salt = Salt}};
handle_cast({change_state, AgState, Data}, State) ->
	%?DEBUG("State:  ~p; Data:  ~p", [AgState, Data]),
	Headjson = {struct, [
		{<<"command">>, <<"astate">>},
		{<<"state">>, AgState},
		{<<"statedata">>, encode_statedata(Data)}
	]},
	Newstate = push_event(Headjson, State),
	{noreply, Midstate} = case Data of
		Call when is_record(Call, call) ->
			{noreply, Newstate#state{current_call = Call}};
		{onhold, Call, calling, _Number} ->
			{noreply, Newstate#state{current_call = Call}};
		_ ->
			{noreply, Newstate#state{current_call = undefined}}
	end,
	Fullstate = case AgState of
		wrapup ->
			Midstate#state{mediaload = undefined};
		_ ->
			Midstate
	end,
	{noreply, Fullstate};
handle_cast({change_state, AgState}, State) ->
	Headjson = {struct, [
			{<<"command">>, <<"astate">>},
			{<<"state">>, AgState}
		]},
	Midstate = push_event(Headjson, State),
	Newstate = case AgState of
		wrapup ->
			Midstate#state{mediaload = undefined};
		_ ->
			Midstate
	end,
	{noreply, Newstate#state{current_call = undefined}};
handle_cast({change_profile, Profile}, State) ->
	Headjson = {struct, [
			{<<"command">>, <<"aprofile">>},
			{<<"profile">>, list_to_binary(Profile)}
		]},
	Newstate = push_event(Headjson, State),
	{noreply, Newstate};
handle_cast({url_pop, URL, Name}, State) ->
	Headjson = {struct, [
			{<<"command">>, <<"urlpop">>},
			{<<"url">>, list_to_binary(URL)},
			{<<"name">>, list_to_binary(Name)}
		]},
	Newstate = push_event(Headjson, State),
	{noreply, Newstate};
handle_cast({blab, Text}, State) ->
	Headjson = {struct, [
		{<<"command">>, <<"blab">>},
		{<<"text">>, list_to_binary(Text)}
	]},
	Newstate = push_event(Headjson, State),
	{noreply, Newstate};
handle_cast(Msg, State) ->
	?DEBUG("Other case ~p", [Msg]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(check_live_poll, #state{poll_pid_established = Last, poll_pid = undefined} = State) ->
	Now = util:now(),
	case Now - Last of
		N when N > 20 ->
			?NOTICE("Stopping due to missed_polls; last:  ~w now: ~w difference: ~w", [Last, Now, Now - Last]),
			{stop, normal, State};
		_N ->
			Tref = erlang:send_after(?TICK_LENGTH, self(), check_live_poll),
			{noreply, State#state{ack_timer = Tref}}
	end;
handle_info(check_live_poll, #state{poll_pid_established = Last, poll_pid = Pollpid} = State) when is_pid(Pollpid) ->
	Tref = erlang:send_after(?TICK_LENGTH, self(), check_live_poll),
	case util:now() - Last of
		N when N > 20 ->
			%?DEBUG("sending pong to initiate new poll pid", []),
			Newstate = push_event({struct, [{success, true}, {<<"command">>, <<"pong">>}, {<<"timestamp">>, util:now()}]}, State),
			{noreply, Newstate#state{ack_timer = Tref}};
		_N ->
			{noreply, State#state{ack_timer = Tref}}
	end;
handle_info({cpx_monitor_event, _Message}, #state{securitylevel = agent} = State) ->
	?WARNING("Not eligible for supervisor view, so shouldn't be getting events.  Unsubbing", []),
	cpx_monitor:unsubscribe(),
	{noreply, State};
handle_info({cpx_monitor_event, Message}, State) ->
	%?DEBUG("Ingesting cpx_monitor_event ~p", [Message]),
	Json = case Message of
		{drop, {Type, Name}} ->
			Fixedname = if 
				is_atom(Name) ->
					 atom_to_binary(Name, latin1); 
				 true -> 
					 list_to_binary(Name) 
			end,
			{struct, [
				{<<"command">>, <<"supervisortab">>},
				{<<"data">>, {struct, [
					{<<"action">>, drop},
					{<<"type">>, Type},
					{<<"id">>, list_to_binary([atom_to_binary(Type, latin1), $-, Fixedname])},
					{<<"name">>, Fixedname}
				]}}
			]};
		{set, {{Type, Name}, Healthprop, Detailprop, _Timestamp}} ->
			Encodedhealth = encode_health(Healthprop),
			Encodeddetail = encode_proplist(Detailprop),
			Fixedname = if 
				is_atom(Name) ->
					 atom_to_binary(Name, latin1); 
				 true -> 
					 list_to_binary(Name) 
			end,
			{struct, [
				{<<"command">>, <<"supervisortab">>},
				{<<"data">>, {struct, [
					{<<"action">>, set},
					{<<"id">>, list_to_binary([atom_to_binary(Type, latin1), $-, Fixedname])},
					{<<"type">>, Type},
					{<<"name">>, Fixedname},
					{<<"display">>, Fixedname},
					{<<"health">>, Encodedhealth},
					{<<"details">>, Encodeddetail}
				]}}
			]}
	end,
	Newstate = push_event(Json, State),
	{noreply, Newstate};
handle_info({'EXIT', Pollpid, Reason}, #state{poll_pid = Pollpid} = State) ->
	case Reason of
		normal ->
			ok;
		_ ->
			?NOTICE("The pollpid died due to ~p", [Reason])
	end,
	{noreply, State#state{poll_pid = undefined}};
handle_info({'EXIT', Pid, Reason}, #state{listener = Pid} = State) ->
	?WARNING("The listener at ~w died due to ~p", [Pid, Reason]),
	{stop, Reason, State};
handle_info({'EXIT', Agent, Reason}, #state{agent_fsm = Agent} = State) ->
	case State#state.poll_pid of
		undefined ->
			ok;
		Pid when is_pid(Pid) ->
			Pid ! {poll, {200, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"forced logout by fsm death">>}]})}},
			ok
	end,
	{stop, Reason, State};
handle_info(Info, State) ->
	?DEBUG("info I can't handle:  ~p", [Info]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
terminate(Reason, State) ->
	?NOTICE("terminated ~p", [Reason]),
	timer:cancel(State#state.ack_timer),
	case State#state.poll_pid of
		undefined ->
			ok;
		Pid when is_pid(Pid) ->
			Pid ! {kill, [], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"forced logout">>}]})},
			ok
	end.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

format_status(normal, [PDict, State]) ->
	[{data, [{"State", format_status(terminate, [PDict, State])}]}];
format_status(terminate, [_PDict, State]) ->
	case State#state.current_call of
		#call{id = ID} ->
			State#state{current_call = ID};
		_ -> State
	end.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

get_nodes("all") ->
	[node() | nodes()];
get_nodes(Nodestring) ->
	case atom_to_list(node()) of
		Nodestring ->
			[node()];
		_Else ->
			F = fun(N) ->
				atom_to_list(N) =/= Nodestring
			end,
			[Out | _Tail] = lists:dropwhile(F, nodes()),
			[Out]
	end.

email_props_to_json(Proplist) ->
	email_props_to_json(Proplist, []).

email_props_to_json([], Acc) ->
	{struct, lists:reverse(Acc)};
email_props_to_json([{Key, Value} | Tail], Acc) ->
	{Dokey, Newkey} = case {is_binary(Key), is_list(Key)} of
		{true, _} -> {ok, Key};
		{_, true} -> {ok, list_to_binary(Key)};
		{_, _} -> {false, false}
	end,
	{Doval, Newval} = case {is_binary(Value), is_list(Value)} of
		{true, _} -> {ok, Value};
		{_, true} -> {ok, email_props_to_json(Value)};
		{_, _} -> {false, false}
	end,
	case {Dokey, Doval} of
		{ok, ok} ->
			email_props_to_json(Tail, [{Newkey, Newval} | Acc]);
		_Else ->
			email_props_to_json(Tail, Acc)
	end.

-type(headers() :: [{string(), string()}]).
-type(mochi_out() :: binary()).
-spec(parse_media_call/3 :: (Mediarec :: #call{}, Command :: {string(), any()}, Response :: any()) -> {headers(), mochi_out()}).
parse_media_call(#call{type = email}, {"attach", _Args}, {ok, Filenames}) ->
	Binnames = lists:map(fun(N) -> list_to_binary(N) end, Filenames),
	Json = {struct, [
		{success, true},
		{<<"filenames">>, Binnames}
	]},
	Html = mochiweb_html:to_html({
		<<"html">>, [], [
			{<<"head">>, [], []},
			{<<"body">>, [], [
				{<<"textarea">>, [], [mochijson2:encode(Json)]}
			]}
		]}),
	%?DEBUG("html:  ~p", [Html]),
	{[], Html};
parse_media_call(#call{type = email}, {"attach", _Args}, {error, Error}) ->
	Json = {struct, [
		{success, false},
		{<<"message">>, Error}
	]},
	Html = mochiweb_html:to_html({
		<<"html">>, [], [
			{<<"head">>, [], []},
			{<<"body">>, [], [
				{<<"textarea">>, [], [mochijson2:encode(Json)]}
			]}
		]}),
	{[], Html};
parse_media_call(#call{type = email}, {"detach", _Args}, {ok, Keys}) ->
	Binnames = lists:map(fun(N) -> list_to_binary(N) end, Keys),
	Json = {struct, [
		{success, true},
		{<<"filenames">>, Binnames}
	]},
	{[], mochijson2:encode(Json)};
parse_media_call(#call{type = email}, {"get_skeleton", _Args}, {Type, Subtype, Heads, Props}) ->
	Json = {struct, [
		{<<"type">>, Type}, 
		{<<"subtype">>, Subtype},
		{<<"headers">>, email_props_to_json(Heads)},
		{<<"properties">>, email_props_to_json(Props)}
	]},
	{[], mochijson2:encode(Json)};
parse_media_call(#call{type = email}, {"get_skeleton", _Args}, {TopType, TopSubType, Tophead, Topprop, Parts}) ->
	Fun = fun
		({Type, Subtype, Heads, Props}, {F, Acc}) ->
			Head = {struct, [
				{<<"type">>, Type},
				{<<"subtype">>, Subtype},
				{<<"headers">>, email_props_to_json(Heads)},
				{<<"properties">>, email_props_to_json(Props)}
			]},
			{F, [Head | Acc]};
		({Type, Subtype, Heads, Props, List}, {F, Acc}) ->
			{_, Revlist} = lists:foldl(F, {F, []}, List),
			Newlist = lists:reverse(Revlist),
			Head = {struct, [
				{<<"type">>, Type},
				{<<"subtype">>, Subtype},
				{<<"headers">>, email_props_to_json(Heads)},
				{<<"properties">>, email_props_to_json(Props)},
				{<<"parts">>, Newlist}
			]},
			{F, [Head | Acc]}
	end,
	{_, Jsonlist} = lists:foldl(Fun, {Fun, []}, Parts),
	Json = {struct, [
		{<<"type">>, TopType}, 
		{<<"subtype">>, TopSubType}, 
		{<<"headers">>, email_props_to_json(Tophead)},
		{<<"properties">>, email_props_to_json(Topprop)},
		{<<"parts">>, lists:reverse(Jsonlist)}]},
	%?DEBUG("json:  ~p", [Json]),
	{[], mochijson2:encode(Json)};
parse_media_call(#call{type = email}, {"get_path", _Path}, {ok, {Type, Subtype, _Headers, _Properties, Body} = Mime}) ->
	Emaildispo = email_media:get_disposition(Mime),
	%?DEBUG("Type:  ~p; Subtype:  ~p;  Dispo:  ~p", [Type, Subtype, Emaildispo]),
	case {Type, Subtype, Emaildispo} of
		{Type, Subtype, {attachment, Name}} ->
			%?DEBUG("Trying to some ~p/~p (~p) as attachment", [Type, Subtype, Name]),
			{[
				{"Content-Disposition", lists:flatten(io_lib:format("attachment; filename=\"~s\"", [binary_to_list(Name)]))},
				{"Content-Type", lists:append([binary_to_list(Type), "/", binary_to_list(Subtype)])}
			], Body};
		{<<"text">>, <<"rtf">>, {inline, Name}} ->
			{[
				{"Content-Disposition", lists:flatten(io_lib:format("attachment; filename=\"~s\"", [binary_to_list(Name)]))},
				{"Content-Type", lists:append([binary_to_list(Type), "/", binary_to_list(Subtype)])}
			], Body};
		{<<"text">>, <<"html">>, _} ->
			Listbody = binary_to_list(Body),
			Parsed = try mochiweb_html:parse(lists:append(["<html>", Listbody, "</html>"])) of
				Islist when is_list(Islist) ->
					Islist;
				Isntlist ->
					[Isntlist]
			catch
				error:function_clause ->
					% most likely there's a doc type, so this would parse out correctly anyway.
					case mochiweb_html:parse(Listbody) of
						Islist when is_list(Islist) ->
							Islist;
						Isntlist ->
							[Isntlist]
					end
			end,
			Lowertag = fun(E) -> string:to_lower(binary_to_list(E)) end,
			Stripper = fun
				(_F, [], Acc) ->
					lists:reverse(Acc);
				(F, [Head | Rest], Acc) when is_tuple(Head) ->
					case Head of
						{comment, _} ->
							F(F, Rest, [Head | Acc]);
						{Tag, _Attr, Kids} ->
							case Lowertag(Tag) of
								"html" ->
									F(F, Kids, []);
								"head" ->
									F(F, Rest, Acc);
								"body" ->
									F(F, Kids, Acc);
								_Else ->
									F(F, Rest, [Head | Acc])
							end
					end;
				(F, [Bin | Rest], Acc) when is_binary(Bin) ->
					F(F, Rest, [Bin | Acc])
			end,
			Newhtml = Stripper(Stripper, Parsed, []),
			{[], mochiweb_html:to_html({<<"span">>, [], Newhtml})};
		{Type, Subtype, _Disposition} ->
			{[{"Content-Type", lists:append([binary_to_list(Type), "/", binary_to_list(Subtype)])}], Body}
%
%		{"text", _, _} ->
%			{[], list_to_binary(Body)};
%		{"image", Subtype, {Linedness, Name}} ->
%			Html = case Linedness of
%				inline ->
%					{<<"img">>, [{<<"src">>, list_to_binary(Name)}], []};
%				attachment ->
%					{<<"a">>, [{<<"href">>, list_to_binary(Name)}], list_to_binary(Name)}
%			end,
%			{[], mochiweb_html:to_html(Html)};
%		{Type, Subtype, Disposition} ->
%			?WARNING("unsure how to handle ~p/~p disposed to ~p", [Type, Subtype, Disposition]),
%			{[], <<"404">>}
	end;
parse_media_call(#call{type = email}, {"get_path", _Path}, {message, Bin}) when is_binary(Bin) ->
	%?DEBUG("Path is a message/Subtype with binary body", []),
	{[], Bin};
parse_media_call(#call{type = email}, {"get_from", _}, undefined) ->
	{[], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"no reply info">>}]})};
parse_media_call(#call{type = email}, {"get_from", _}, {Label, Address}) ->
	Json = {struct, [
		{<<"label">>, Label},
		{<<"address">>, Address}
	]},
	{[], mochijson2:encode({struct, [{success, true}, {<<"data">>, Json}]})};
parse_media_call(Mediarec, Command, Response) ->
	?WARNING("Unparsable result for ~p:~p.  ~p", [Mediarec#call.type, element(1, Command), Response]),
	{[], mochijson2:encode({struct, [{success, false}, {<<"message">>, <<"unparsable result for command">>}]})}.

-spec(do_action/3 :: (Nodes :: [atom()], Do :: any(), Acc :: [any()]) -> {'true' | 'false', any()}).
do_action([], _Do, Acc) ->
	{true, Acc};
%% get a list of the agent profiles and how many agents are logged into each
do_action([Node | Tail], ["agent_profiles"] = Do, Acc) ->
	Profiles = agent_auth:get_profiles(),
	Makeprops = fun(#agent_profile{name = Name}) ->
		{Name, 0}
	end,
	Dict = dict:from_list(lists:map(Makeprops, Profiles)),
	Agents = case rpc:call(Node, agent_manager, list, [], 1000) of
		{badrpc, timeout} ->
			[];
		Else ->
			Else
	end,
	F = fun({_Login, Pid}, Accin) -> 
		#agent{profile = Profile} = agent:dump_state(Pid),
		dict:store(Profile, dict:fetch(Profile, Accin) + 1, Accin)
	end,
	Newdict = lists:foldl(F, Dict, Agents),
	Proplist = dict:to_list(Newdict),
	Makestruct = fun({Name, Count}) ->
		{struct, [{<<"name">>, list_to_binary(Name)}, {<<"count">>, Count}]}
	end,
	Newacc = [{struct, [{<<"node">>, list_to_binary(atom_to_list(Node))}, {<<"profiles">>, lists:map(Makestruct, Proplist)}]} | Acc],
	do_action(Tail, Do, Newacc);
%% get a list of the queues, and how many calls are in each.
do_action([Node | Tail], ["queues"] = Do, Acc) ->
	Queuedict = case rpc:call(Node, queue_manager, print, [], 1000) of
		{badrpc, timeout} ->
			dict:new();
		Else ->
			Else
	end,
	Queuelist = dict:to_list(Queuedict),
	Makeprops = fun({Qname, Qpid}) ->
		Count = call_queue:call_count(Qpid),
		{struct, [{<<"name">>, list_to_binary(Qname)}, {<<"count">>, Count}]}
	end,
	Queues = lists:map(Makeprops, Queuelist),
	Newacc = [{struct, [{<<"node">>, list_to_binary(atom_to_list(Node))}, {<<"queues">>, Queues}]} | Acc],
	do_action(Tail, Do, Newacc);
%% get the agents that are a member of the given profile, and thier data.
do_action([Node | Tail], ["agent", Profile] = Do, Acc) ->
	Binprof = list_to_binary(Profile),
	Agents = case rpc:call(Node, agent_manager, list, [], 1000) of
		{badrpc, timeout} ->
			[];
		Else ->
			Else
	end,
	States = lists:map(fun({_, Pid}) -> agent:dump_state(Pid) end, Agents),
	Filter = fun(#agent{profile = Aprof}) ->
		list_to_binary(Aprof) =:= Binprof
	end,
	Filtered = lists:filter(Filter, States),
	Agentstructs = encode_agents(Filtered, []),
	Newacc = [{struct, [{<<"node">>, list_to_binary(atom_to_list(Node))}, {<<"agents">>, Agentstructs}]} | Acc],
	do_action(Tail, Do, Newacc);
%% get the agent state data (id call).
do_action([_Node | _Tail], ["agent", Agent, "callid"], _Acc) ->
	case agent_manager:query_agent(Agent) of
		false ->
			{false, <<"agent not found">>};
		{true, Pid} ->
			#agent{statedata = Call} = agent:dump_state(Pid),
			case Call of
				Call when is_record(Call, call) ->
					{true, encode_call(Call)};
				_Else ->
					{false, <<"not a call">>}
			end
	end;
%% get a summary of the given queue
do_action([_Node | _Tail], ["queue", Queue], _Acc) ->
	case queue_manager:get_queue(Queue) of
		undefined ->
			{false, <<"no such queue">>};
		Pid when is_pid(Pid) ->
			Weight = call_queue:get_weight(Pid),
			Count = call_queue:call_count(Pid),
			Calls = encode_queue_list(call_queue:get_calls(Pid), []),
			Encoded = {struct, [
				{<<"weight">>, Weight},
				{<<"count">>, Count},
				{<<"calls">>, Calls}
			]},
			{true, Encoded}
	end;
%% get a call from the given queue
do_action([_Node | _Tail], ["queue", Queue, Callid], _Acc) ->
	case queue_manager:get_queue(Queue) of
		undefined ->
			{false, <<"no such queue">>};
		Pid when is_pid(Pid) ->
			case call_queue:get_call(Pid, Callid) of
				{{Weight, {Mega, Sec, _Micro}}, Call} ->
					{struct, Preweight} = encode_call(Call),
					Time = (Mega * 100000) + Sec,
					Props = lists:append([{<<"weight">>, Weight}, {<<"queued">>, Time}], Preweight),
					{true, {struct, Props}};
				none ->
					{false, <<"no such call">>}
			end
	end;
do_action(Nodes, Do, _Acc) ->
	?INFO("Bumping back unknown request ~p for nodes ~p", [Do, Nodes]),
	{false, <<"unknown request">>}.

encode_agent(Agent) when is_record(Agent, agent) ->
	%{Mega, Sec, _Micro} = Agent#agent.lastchange,
	%Now = (Mega * 1000000) + Sec,
	%Remnum = case Agent#agent.remotenumber of
		%undefined ->
			%<<"undefined">>;
		%Else when is_list(Else) ->
			%list_to_binary(Else)
	%end,
	Prestatedata = [
		{<<"login">>, list_to_binary(Agent#agent.login)},
		{<<"skills">>, cpx_web_management:encode_skills(Agent#agent.skills)},
		{<<"profile">>, list_to_binary(Agent#agent.profile)},
		{<<"state">>, Agent#agent.state},
		{<<"lastchanged">>, Agent#agent.lastchange}
		%{<<"remotenumber">>, Remnum}
	],
	Statedata = case Agent#agent.statedata of
		Call when is_record(Call, call) ->
			list_to_binary(Call#call.id);
		_Else ->
			<<"niy">>
	end,
	Proplist = [{<<"statedata">>, Statedata} | Prestatedata],
	{struct, Proplist}.

encode_agents([], Acc) -> 
	lists:reverse(Acc);
encode_agents([Head | Tail], Acc) ->
	encode_agents(Tail, [encode_agent(Head) | Acc]).

encode_call(Call) when is_record(Call, call) ->
	{struct, [
		{<<"id">>, list_to_binary(Call#call.id)},
		{<<"type">>, Call#call.type},
		{<<"callerid">>, list_to_binary(element(1, Call#call.callerid) ++ " " ++ element(2, Call#call.callerid))},
		{<<"client">>, encode_client(Call#call.client)},
		{<<"skills">>, cpx_web_management:encode_skills(Call#call.skills)},
		{<<"ringpath">>, Call#call.ring_path},
		{<<"mediapath">>, Call#call.media_path}
	]};
encode_call(Call) when is_record(Call, queued_call) ->
	Basecall = gen_server:call(Call#queued_call.media, get_call),
	{struct, Encodebase} = encode_call(Basecall),
	Newlist = [{<<"skills">>, cpx_web_management:encode_skills(Call#queued_call.skills)} | proplists:delete(<<"skills">>, Encodebase)],
	{struct, Newlist}.

%encode_calls([], Acc) ->
%	lists:reverse(Acc);
%encode_calls([Head | Tail], Acc) ->
%	encode_calls(Tail, [encode_call(Head) | Acc]).

encode_client(Client) when is_record(Client, client) ->
	{struct, [
		{<<"label">>, list_to_binary(Client#client.label)},
		{<<"id">>, list_to_binary(Client#client.id)}
	]};
encode_client(_) ->
	undefined.

%encode_clients([], Acc) ->
%	lists:reverse(Acc);
%encode_clients([Head | Tail], Acc) ->
%	encode_clients(Tail, [encode_client(Head) | Acc]).

encode_queue_list([], Acc) ->
	lists:reverse(Acc);
encode_queue_list([{{Priority, {Mega, Sec, _Micro}}, Call} | Tail], Acc) ->
	Time = (Mega * 1000000) + Sec,
	Struct = {struct, [
		{<<"queued">>, Time},
		{<<"priority">>, Priority},
		{<<"id">>, list_to_binary(Call#queued_call.id)}
	]},
	Newacc = [Struct | Acc],
	encode_queue_list(Tail, Newacc).

encode_stats(Stats) ->
	encode_stats(Stats, 1, []).

encode_stats([], Count, Acc) ->
	{Count - 1, Acc};
encode_stats([Head | Tail], Count, Acc) ->
	Proplisted = cpx_monitor:to_proplist(Head),
	Protohealth = proplists:get_value(health, Proplisted),
	Protodetails = proplists:get_value(details, Proplisted),
	Display = case {proplists:get_value(name, Proplisted), proplists:get_value(type, Proplisted)} of
		{_Name, agent} ->
			Login = proplists:get_value(login, Protodetails),
			[{<<"display">>, list_to_binary(Login)}];
		{Name, _} when is_binary(Name) ->
			[{<<"display">>, Name}];
		{Name, _} when is_list(Name) ->
			[{<<"display">>, list_to_binary(Name)}];
		{Name, _} when is_atom(Name) ->
			[{<<"display">>, Name}]
	end,
	Type = [{<<"type">>, proplists:get_value(type, Proplisted)}],
	[{_, Rawtype}] = Type,
	Id = case {Display, proplists:get_value(type, Proplisted)} of
		{_, agent} ->
			[{<<"id">>, list_to_binary(lists:append([atom_to_list(agent), "-", proplists:get_value(name, Proplisted)]))}];
		{[{_, D}], _} when is_atom(D) ->
			[{<<"id">>, list_to_binary(lists:append([atom_to_list(Rawtype), "-", atom_to_list(D)]))}];
		{[{_, D}], _} when is_binary(D) ->
			[{<<"id">>, list_to_binary(lists:append([atom_to_list(Rawtype), "-", binary_to_list(D)]))}]
	end,
	Node = case Type of
		[{_, system}] ->
			[];
		[{_, node}] ->
			[];
		[{_, _Else}] ->
			[{node, proplists:get_value(node, Protodetails)}]
	end,
	Parent = case Type of
		[{_, system}] ->
			[];
		[{_, node}] ->
			[];
		[{_, agent}] ->
			[{<<"profile">>, list_to_binary(proplists:get_value(profile, Protodetails))}];
		[{_, queue}] ->
			[{<<"group">>, list_to_binary(proplists:get_value(group, Protodetails))}];
		[{_, media}] ->
			case {proplists:get_value(agent, Protodetails), proplists:get_value(queue, Protodetails)} of
				{undefined, undefined} ->
					?DEBUG("Ignoring ~p as it's likely in ivr (no agent/queu)", [proplists:get_value(name, Proplisted)]),
					[];
				{undefined, Queue} ->
					[{queue, list_to_binary(Queue)}];
				{Agent, undefined} ->
					[{agent, list_to_binary(Agent)}]
			end
	end,
	Scrubbedhealth = encode_health(Protohealth),
	Scrubbeddetails = Protodetails,
	Health = [{<<"health">>, {struct, [{<<"_type">>, <<"details">>}, {<<"_value">>, Scrubbedhealth}]}}],
	Details = [{<<"details">>, {struct, [{<<"_type">>, <<"details">>}, {<<"_value">>, encode_proplist(Scrubbeddetails)}]}}],
	Encoded = lists:append([Id, Display, Type, Node, Parent, Health, Details]),
	Newacc = [{struct, Encoded} | Acc],
	encode_stats(Tail, Count + 1, Newacc).

-spec(encode_health/1 :: (Health :: [{atom(), any()}]) -> json_simple()).
encode_health(Health) ->
	List = encode_health(Health, []),
	{struct, List}.

encode_health([], Acc) ->
	Acc;
encode_health([{Key, {Min, Goal, Max, {time, Time}}} | Tail], Acc) ->
	Json = {struct, [
		{<<"min">>, Min},
		{<<"goal">>, Goal},
		{<<"max">>, Max},
		{<<"time">>, Time}
	]},
	encode_health(Tail, [{Key, Json} | Acc]);
encode_health([{Key, {Min, Goal, Max, Val}} | Tail], Acc) ->
	Json = {struct, [
		{<<"min">>, Min},
		{<<"goal">>, Goal},
		{<<"max">>, Max},
		{<<"value">>, Val}
	]},
	encode_health(Tail, [{Key, Json} | Acc]);
encode_health([{Key, Val} | Tail], Acc) ->
	Newacc = case Val of
		Val when is_integer(Val); is_float(Val); is_binary(Val); is_atom(Val) ->
			[{Key, Val} | Acc];
		Val when is_list(Val) ->
			[{Key, list_to_binary(Val)} | Acc];
		Val ->
			Acc
	end,
	encode_health(Tail, Newacc);
encode_health([Key | Tail], Acc) when is_atom(Key) ->
	encode_health(Tail, [{Key, true} | Acc]);
encode_health([_Whatever | Tail], Acc) ->
	encode_health(Tail, Acc).
	
	
-spec(encode_groups/2 :: (Stats :: [{string(), string()}], Count :: non_neg_integer()) -> {non_neg_integer(), [tuple()]}).
encode_groups(Stats, Count) ->
	%?DEBUG("Stats to encode:  ~p", [Stats]),
	encode_groups(Stats, Count + 1, [], [], []).

-spec(encode_groups/5 :: (Groups :: [{string(), string()}], Count :: non_neg_integer(), Acc :: [tuple()], Gotqgroup :: [string()], Gotaprof :: [string()]) -> {non_neg_integer(), [tuple()]}).
encode_groups([], Count, Acc, Gotqgroup, Gotaprof) ->
	F = fun() ->
		Qqh = qlc:q([{Qgroup, "queuegroup"} || #queue_group{name = Qgroup} <- mnesia:table(queue_group), lists:member(Qgroup, Gotqgroup) =:= false]),
		Aqh = qlc:q([{Aprof, "agentprofile"} || #agent_profile{name = Aprof} <- mnesia:table(agent_profile), lists:member(Aprof, Gotaprof) =:= false]),
		Qgroups = qlc:e(Qqh),
		Aprofs = qlc:e(Aqh),
		lists:append(Qgroups, Aprofs)
	end,
	Encode = fun({Name, Type}) ->
		{struct, [
			{<<"id">>, list_to_binary(lists:append([Type, "-", Name]))},
			{<<"type">>, list_to_binary(Type)},
			{<<"display">>, list_to_binary(Name)},
			{<<"health">>, {struct, [
				{<<"_type">>, <<"details">>},
				{<<"_value">>, {struct, []}}
			]}}
		]}
	end,
	{atomic, List} = mnesia:transaction(F),
	Encoded = lists:map(Encode, List),
	Newacc = lists:append([Acc, Encoded]),
	{Count + length(Newacc), Newacc};
encode_groups([{Type, Name} | Tail], Count, Acc, Gotqgroup, Gotaprof) ->
	Out = {struct, [
		{<<"id">>, list_to_binary(lists:append([Type, "-", Name]))},
		{<<"type">>, list_to_binary(Type)},
		{<<"display">>, list_to_binary(Name)},
		{<<"health">>, {struct, [
			{<<"_type">>, <<"details">>},
			{<<"_value">>, {struct, []}}
		]}}
	]},
	{Ngotqgroup, Ngotaprof} = case Type of
		"queuegroup" ->
			{[Name | Gotqgroup], Gotaprof};
		"agentprofile" ->
			{Gotqgroup, [Name | Gotaprof]}
	end,
	encode_groups(Tail, Count + 1, [Out | Acc], Ngotqgroup, Ngotaprof).
		
encode_proplist(Proplist) ->
	Struct = encode_proplist(Proplist, []),
	{struct, Struct}.
	
encode_proplist([], Acc) ->
	lists:reverse(Acc);
encode_proplist([Entry | Tail], Acc) when is_atom(Entry) ->
	Newacc = [{Entry, true} | Acc],
	encode_proplist(Tail, Newacc);
encode_proplist([{Key, {timestamp, Num}} | Tail], Acc) when is_integer(Num) ->
	Newacc = [{Key, {struct, [{timestamp, Num}]}} | Acc],
	encode_proplist(Tail, Newacc);
encode_proplist([{Key, Value} | Tail], Acc) when is_list(Value) ->
	Newval = list_to_binary(Value),
	Newacc = [{Key, Newval} | Acc],
	encode_proplist(Tail, Newacc);
encode_proplist([{Key, Value} = Head | Tail], Acc) when is_atom(Value), is_atom(Key) ->
	encode_proplist(Tail, [Head | Acc]);
encode_proplist([{Key, Value} | Tail], Acc) when is_binary(Value); is_float(Value); is_integer(Value) ->
	Newacc = [{Key, Value} | Acc],
	encode_proplist(Tail, Newacc);
encode_proplist([{Key, Value} | Tail], Acc) when is_record(Value, client) ->
	Label = case Value#client.label of
		undefined ->
			undefined;
		_ ->
			list_to_binary(Value#client.label)
	end,
	encode_proplist(Tail, [{Key, Label} | Acc]);
encode_proplist([{callerid, {CidName, CidDAta}} | Tail], Acc) ->
	CidNameBin = list_to_binary(CidName),
	CidDAtaBin = list_to_binary(CidDAta),
	Newacc = [{callid_name, CidNameBin} | [{callid_data, CidDAtaBin} | Acc ]],
	encode_proplist(Tail, Newacc);
encode_proplist([{Key, Media} | Tail], Acc) when is_record(Media, call) ->
	Simple = [{callerid, Media#call.callerid},
	{type, Media#call.type},
	{client, Media#call.client},
	{direction, Media#call.direction},
	{id, Media#call.id}],
	Json = encode_proplist(Simple),
	encode_proplist(Tail, [{Key, Json} | Acc]);
encode_proplist([{Key, {onhold, Media, calling, Number}} | Tail], Acc) when is_record(Media, call) ->
	Simple = [
		{callerid, Media#call.callerid},
		{type, Media#call.type},
		{client, Media#call.client},
		{direction, Media#call.direction},
		{id, Media#call.id},
		{calling, list_to_binary(Number)}
	],
	Json = encode_proplist(Simple),
	encode_proplist(Tail, [{Key, Json} | Acc]);
encode_proplist([_Head | Tail], Acc) ->
	encode_proplist(Tail, Acc).

extract_groups(Stats) ->
	%?DEBUG("Stats to extract groups from:  ~p", [Stats]),
	extract_groups(Stats, []).

extract_groups([], Acc) ->
	Acc;
extract_groups([Head | Tail], Acc) ->
	Proplisted = cpx_monitor:to_proplist(Head),
	Details = proplists:get_value(details, Proplisted, []),
	case proplists:get_value(type, Proplisted) of
		queue ->
			Display = proplists:get_value(group, Details),
			case lists:member({"queuegroup", Display}, Acc) of
				true ->
					extract_groups(Tail, Acc);
				false ->
					Top = {"queuegroup", Display},
					extract_groups(Tail, [Top | Acc])
			end;
		agent ->
			Display = proplists:get_value(profile, Details),
			case lists:member({"agentprofile", Display}, Acc) of
				true ->
					extract_groups(Tail, Acc);
				false ->
					Top = {"agentprofile", Display},
					extract_groups(Tail, [Top | Acc])
			end;
		_Else ->
			%?DEBUG("no group to extract for type ~w", [_Else]),
			extract_groups(Tail, Acc)
	end.

-spec(push_event/2 :: (Eventjson :: json_simple(), State :: #state{}) -> #state{}).
push_event(Eventjson, State) ->
	Newqueue = [Eventjson | State#state.poll_queue],
	case State#state.poll_pid of
		undefined ->
			%?DEBUG("No poll pid to send to", []),
			State#state{poll_queue = Newqueue};
		Pid when is_pid(Pid) ->
			%?DEBUG("Sending to the ~w", [Pid]),
			Pid ! {poll, {200, [], mochijson2:encode({struct, [{success, true}, {<<"data">>, lists:reverse(Newqueue)}]})}},
			unlink(Pid),
			State#state{poll_queue = [], poll_pid = undefined, poll_pid_established = util:now()}
	end.

-ifdef(TEST).





check_live_poll_test_() ->
	{timeout, ?TICK_LENGTH * 5, fun() -> [
	{"When poll pid is undefined, and less than 10 seconds have passed",
	fun() ->
		?DEBUG("timeout:  ~p", [?TICK_LENGTH * 5]),
		State = #state{poll_pid_established = util:now(), poll_pid = undefined},
		?assertMatch({noreply, NewState}, handle_info(check_live_poll, State)),
		?DEBUG("Starting recieve", []),
		Ok = receive
			check_live_poll ->
				true
		after ?TICK_LENGTH + 1 ->
			false
		end,
		?assert(Ok)
	end},
	{"When poll pid is undefined, and more than 10 seconds have passed",
	fun() ->
		State = #state{poll_pid_established = util:now() - 12, poll_pid = undefined},
		?assertEqual({stop, normal, State}, handle_info(check_live_poll, State)),
		Ok = receive
			check_live_poll	->
				 false
		after ?TICK_LENGTH + 1 ->
			true
		end,
		?assert(Ok)
	end},
	{"When poll pid exists, and less than 20 seconds have passed",
	fun() ->
		State = #state{poll_pid_established = util:now() - 5, poll_pid = self()},
		{noreply, Newstate} = handle_info(check_live_poll, State),
		?assertEqual([], Newstate#state.poll_queue),
		Ok = receive
			check_live_poll ->
				 true
		after ?TICK_LENGTH + 1 ->
			false
		end,
		?assert(Ok)
	end},
	{"When poll pid exists, and more than 20 seconds have passed",
	fun() ->
		State = #state{poll_pid_established = util:now() - 25, poll_pid = self()},
		{noreply, Newstate} = handle_info(check_live_poll, State),
		?assertEqual([], Newstate#state.poll_queue),
		Ok = receive
			check_live_poll	->
				 true
		after ?TICK_LENGTH + 1 ->
			false
		end,
		?assert(Ok)
	end}] end}.



%
%
%
%handle_info(check_live_poll, #state{poll_pid_established = Last, poll_pid = undefined} = State) ->
%	Now = util:now(),
%	case Now - Last of
%		N when N > 10 ->
%			?NOTICE("Stopping due to missed_polls; last:  ~w now: ~w difference: ~w", [Last, Now, Now - Last]),
%			{stop, missed_polls, State};
%		_N ->
%			Tref = erlang:send_after(?TICK_LENGTH, self(), check_live_poll),
%			{noreply, State#state{ack_timer = Tref}}
%	end;
%handle_info(check_live_poll, #state{poll_pid_established = Last, poll_pid = Pollpid} = State) when is_pid(Pollpid) ->
%	Tref = erlang:send_after(?TICK_LENGTH, self(), check_live_poll),
%	case util:now() - Last of
%		N when N > 20 ->
%			Newstate = push_event({struct, [{success, true}, {<<"command">>, <<"pong">>}, {<<"timestamp">>, util:now()}]}, State),
%			{noreply, Newstate#state{ack_timer = Tref}};
%		_N ->
%			{noreply, State#state{ack_timer = Tref}}
%	end;
%
%



set_state_test_() ->
	{
		foreach,
		fun() ->
			%agent_manager:start([node()]),
			gen_leader_mock:start(agent_manager),
			gen_leader_mock:expect_leader_call(agent_manager, 
				fun({exists, "testagent"}, _From, State, _Elec) -> 
					{ok, Apid} = agent:start(#agent{login = "testagent"}),
					{ok, {true, Apid}, State} 
				end),
			{ok, Connpid} = agent_web_connection:start(#agent{login = "testagent", skills = [english]}, agent),
			{Connpid}
		end,
		fun({Connpid}) ->
			stop(Connpid)
			%agent_auth:stop(),
			%agent_manager:stop()
		end,
		[
			fun({Connpid}) ->
				{"Set state valid",
				fun() ->
					Reply = gen_server:call(Connpid, {set_state, "idle"}),
					?assertEqual({200, [], [123, [34,"success", 34], 58,<<"true">>, 44, [34,<<"status">>, 34], 58, [34,"ok", 34], 125]}, Reply),
					Reply2 = gen_server:call(Connpid, {set_state, "released", "Default"}),
					?assertEqual({200, [], [123, [34,"success", 34], 58,<<"true">>, 44, [34,<<"status">>, 34], 58, [34,"ok", 34], 125]}, Reply2)
				end}
			end,
			fun({Connpid}) ->
				{"Set state invalid",
				fun() ->
					Reply = gen_server:call(Connpid, {set_state, "wrapup"}),
					?CONSOLE("~p", [Reply]),
					?assertEqual({200, [], [123, [34,"success", 34], 58,<<"false">>, 44, [34,<<"status">>, 34], 58, [34,"invalid", 34], 125]}, Reply),
					Reply2 = gen_server:call(Connpid, {set_state, "wrapup", "garbage"}),
					?CONSOLE("~p", [Reply2]),
					?assertEqual({200, [], [123, [34,"success", 34], 58,<<"false">>, 44, [34,<<"status">>, 34], 58, [34,"invalid", 34], 125]}, Reply2)
				end}
			end
		]
	}.

extract_groups_test() ->
	Rawlist = [
		{{queue, "queue1"}, [], [{group, "group1"}]},
		{{queue, "queue2"}, [], [{group, "Default"}]},
		{{agent, "agent1"}, [], [{profile, "profile1"}]},
		{{media, "media1"}, [], []},
		{{queue, "queue3"}, [], [{group, "Default"}]},
		{{agent, "agent2"}, [], [{profile, "Default"}]},
		{{agent, "agent3"}, [], [{profile, "profile1"}]}
	],
	Expected = [
		{"agentprofile", "Default"},
		{"agentprofile", "profile1"},
		{"queuegroup", "Default"},
		{"queuegroup", "group1"}
	],
	Out = extract_groups(Rawlist),
	?assertEqual(Expected, Out).

encode_proplist_test() ->
	Input = [
		boolean,
		{list, "This is a list"},
		{keyatom, valatom},
		{binary, <<"binary data">>},
		{integer, 42},
		{float, 23.5},
		{tuple, {<<"this">>, <<"gets">>, <<"stripped">>}}
	],
	Expected = {struct, [
		{boolean, true},
		{list, <<"This is a list">>},
		{keyatom, valatom},
		{binary, <<"binary data">>},
		{integer, 42},
		{float, 23.5}
	]},
	Out = encode_proplist(Input),
	?assertEqual(Expected, Out).
		
-define(MYSERVERFUNC, 
	fun() ->
		["testpx", _Host] = string:tokens(atom_to_list(node()), "@"),
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		%mnesia:start(),
		%agent_auth:start(),
		Agent = #agent{login = "agent", skills = [english]},
		{ok, Fsmpid} = agent:start(Agent),
		gen_leader_mock:start(agent_manager),
		gen_leader_mock:expect_leader_call(agent_manager, fun({exists, "agent"}, _From, State, _Elec) -> {ok, {true, Fsmpid}, State} end),
		%agent_manager:start([node()]),
		%agent_auth:start(),
		{ok, Pid} = start_link(Agent, agent),
		unlink(Pid),
		Stopfun = fun() ->
			?CONSOLE("stopping agent_auth", []),
			%agent_auth:stop(),
			?CONSOLE("stopping agent_manager", []),
			%agent_manager:stop(),
			gen_leader_mock:stop(agent_manager),
			?CONSOLE("stopping web_connection at ~p: ~p", [Pid, is_process_alive(Pid)]),
			stop(Pid),
			?CONSOLE("stopping mnesia", []),
			mnesia:stop(),
			?CONSOLE("deleting schema", []),
			mnesia:delete_schema([node()]),
			?CONSOLE("all done", [])
		end,
		{Pid, Stopfun}
	end
).

%-include("gen_server_test.hrl").


-endif.
