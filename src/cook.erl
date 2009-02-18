%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%% 
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%% 
%% The Original Code is Spice Telphony.
%% 
%% The Initial Developer of the Original Code is 
%% Andrew Thompson and Micah Warren.
%% Portions created by the Initial Developers are Copyright (C) 
%% SpiceCSM. All Rights Reserved.

%% Contributor(s): 

%% Andrew Thompson <athompson at spicecsm dot com>
%% Micah Warren <mwarren at spicecsm dot com>
%% 

%% @doc The cook is a process that is spawned per call in queue, it
%% executes the queue's 'recipe' on the call and handles call delivery to an
%% agent. When it finds one or more dispatchers bound to its call it requests
%% that each dispatcher generate a list of local agents matching the call's
%% criteria and selects the best one to offer it to.
-module(cook).
-author("Micah").

-behaviour(gen_server).

-include("call.hrl").
-include("agent.hrl").
-include("queue.hrl").

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-define(TICK_LENGTH, 500).
-else.
-define(TICK_LENGTH, 10000).
-endif.

-define(RINGOUT, 4).

%% API
-export([start_link/3, start/3, stop/1, restart_tick/1, stop_tick/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	terminate/2, code_change/3]).

-record(state, {
		recipe = [] :: recipe(),
		ticked = 0 :: integer(), % number of ticks we've done
		call :: string() | 'undefined',
		queue :: string() | 'undefined',
		continue = true :: bool(),
		ringingto :: pid(),
		ringcount = 0 :: non_neg_integer(),
		tref :: any() % timer reference
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Starts a cook linked to the parent process for `Call' processed by `Recipe' for call_queue named `Queue'.
-spec(start_link/3 :: (Call :: string(), Recipe :: recipe(), Queue :: string()) -> {'ok', pid()}).
start_link(Call, Recipe, Queue) when is_pid(Call) ->
    gen_server:start_link(?MODULE, [Call, Recipe, Queue], []).

%% @doc Starts a cook not linked to the parent process for `Call' processed by `Recipe' for call_queue named `Queue'.
-spec(start/3 :: (Call :: string(), Recipe :: recipe(), Queue :: string()) -> {'ok', pid()}).
start(Call, Recipe, Queue) when is_pid(Call) -> 
	gen_server:start(?MODULE, [Call, Recipe, Queue], []).
	
%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([Call, Recipe, Queue]) ->
	% TODO check for a call right away.
	?CONSOLE("Queue:  ~p", [Queue]),
	process_flag(trap_exit, true),
	{ok, Tref} = timer:send_interval(?TICK_LENGTH, do_tick),
	State = #state{ticked=0, recipe=Recipe, call=Call, queue=Queue, tref=Tref},
    {ok, State}.

%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------
%% @private
handle_call(stop, _From, State) ->
	{stop, normal, ok, State};
handle_call(Request, _From, State) ->
    {reply, {unknown_call, Request}, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
%% @private
handle_cast(restart_tick, State) ->
	State2 = do_tick(State),
	{ok, Tref} = timer:send_interval(?TICK_LENGTH, do_tick),
	{noreply, State2#state{tref=Tref}};
handle_cast(stop_tick, State) -> 
	timer:cancel(State#state.tref),
	{noreply, State#state{tref=undefined}};
handle_cast({stop_ringing, AgentPid}, State) when AgentPid =:= State#state.ringingto ->
	%% TODO - actually tell the backend to stop ringing if it's an outband ring
	{noreply, State#state{ringingto=undefined}};
handle_cast(remove_from_queue, State) ->
	Qpid = queue_manager:get_queue(State#state.queue),
	call_queue:remove(Qpid, State#state.call),
	{noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
%% @private
handle_info(do_tick, State) -> 
	case whereis(queue_manager) of
		undefined -> 
			{stop, queue_manager_undefined, State};
		_Else -> 
			case queue_manager:get_queue(State#state.queue) of
				undefined -> 
					{stop, {queue_undefined, State#state.queue}, State};
				_Other -> 
					{noreply, do_tick(State)}
			end
	end;
%handle_info({'EXIT', Pid, _Reason}, State) -> 
%	?CONSOLE("queue ~p died, suspending self", [State#state.queue]),
%	timer:cancel(State#state.tref),
%	Qpid = wait_for_queue(State#state.queue),
%	?CONSOLE("queue's back up, trying to add it to call", []),
%	call_queue:add(Qpid, State#state.call),
%	State2 = do_tick(State),
%	{ok, Tref} = timer:send_interval(?TICK_LENGTH, do_tick),
%	{noreply, State2#state{tref=Tref}};
handle_info(Info, State) ->
	?CONSOLE("received random info message: ~p", [Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
%% @private
terminate(normal, _State) -> 
	?CONSOLE("normal Graceful death", []),
	ok;
terminate(shutdown, _State) -> 
	?CONSOLE("shutdown graceful death", []),
	ok;
terminate(Reason, State) ->
	?CONSOLE("Hagurk!  ~p", [Reason]),
	timer:cancel(State#state.tref),
	Qpid = wait_for_queue(State#state.queue),
	?CONSOLE("Looks like the queue recovered, I can die now",[]),
	call_queue:add(Qpid, State#state.call),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% @doc Restart the cook at `Pid'.
restart_tick(Pid) -> 
	gen_server:cast(Pid, restart_tick).

%% @doc Pause the cook running at `Pid'.
stop_tick(Pid) -> 
	gen_server:cast(Pid, stop_tick).

wait_for_queue(Qname) ->
	case whereis(queue_manager) of
		undefined -> 
			?CONSOLE("Waiting on the queue manager", []),
			receive
			after 1000 ->
				ok
			end;
		QMPid when is_pid(QMPid) -> 
			?CONSOLE("Queue manager is available", []),
			ok
	end,
	case queue_manager:get_queue(Qname) of
		undefined -> 
			?CONSOLE("Waiting on queue ~p" , [Qname]),
			receive
			after 300 ->
				ok
			end,
			wait_for_queue(Qname);
		Qpid when is_pid(Qpid) -> 
			?CONSOLE("Queue ~p is back up", [Qname]),
			Qpid
	end.

%% @private
-spec(do_tick/1 :: (State :: #state{}) -> #state{}).
do_tick(#state{recipe=Recipe} = State) -> 
	State2 = do_route(State),
	Recipe2 = do_recipe(Recipe, State2),
	State2#state{ticked= State2#state.ticked+1, recipe=Recipe2}.

stop(Pid) -> 
	gen_server:call(Pid, stop).

%% @private
-spec(do_route/1 :: (State :: #state{}) -> #state{}).
do_route(State) when State#state.ringingto =/= undefined, State#state.ringcount =< ?RINGOUT ->
	?CONSOLE("still ringing: ~p of ~p times", [State#state.ringcount, ?RINGOUT]),
	State#state{ringcount=State#state.ringcount +1};
do_route(State) when State#state.ringingto =/= undefined, State#state.ringcount > ?RINGOUT ->
	?CONSOLE("rang out",[]),
	agent:set_state(State#state.ringingto, idle),
	do_route(State#state{ringingto=undefined});
do_route(State) when State#state.ringingto =:= undefined ->
	?CONSOLE("starting new ring~n",[]),
	Qpid = queue_manager:get_queue(State#state.queue),
	case call_queue:get_call(Qpid, State#state.call) of
		{_Key, Call} ->
			case Call#queued_call.dispatchers of
				[] -> 
					% if there are no dispatchers bound to the call,
					% there are no agents available
					State;
				% get the list of agents from the dispatchers, then flatten it.
				Dispatchers -> 
					F = fun(Dpid) -> 
						try dispatchers:get_agents(Dpid) of
							[] -> 
								?CONSOLE("empty list, might as well tell this dispatcher to regrab", []),
								dispatchers:regrab(Dpid),
								[];
							Ag -> 
								Ag
						catch
							_:_ -> 
								[]
						end
					end,
					Agents = lists:map(F, Dispatchers),
					Agents2 = lists:flatten(Agents),

					%io:format("Got agents ~p for call ~p~n", [Agents2, Call]),
				
					% calculate costs and sort by same.
					Agents3 = lists:sort([{ARemote + Askills + Aidle, APid} || 
						{_AName, APid, AState} <- Agents2, 
						ARemote <- 
							case APid of
								_X when node() =:= node(APid) -> 
									[0]; 
								_Y -> 
									[15] % TODO macro the magic number
							end,
							Askills <- [length(AState#agent.skills)],
							Aidle <- [element(2, AState#agent.lastchangetimestamp)]]),
					% offer the call to each agent.
					case offer_call(Agents3, Call) of
						none ->
							State;
						Agent ->
							State#state{ringingto=Agent, ringcount=0}
					end
			end;
		 none -> 
			% TODO if the call is not in queue, this should die
			 State
	end.

%% @private
-spec(offer_call/2 :: (Agents :: [{non_neg_integer, pid()}], Call :: #call{}) -> 'none' | pid()).
offer_call([], _Call) -> 
	none;
offer_call([{_ACost, Apid} | Tail], Call) -> 
	case gen_server:call(Call#call.source, {ring_agent, Apid, Call}) of
		ok ->
			?CONSOLE("cook offering call:  ~p to ~p", [Call, Apid]),
			Apid;
		invalid -> 
			offer_call(Tail, Call)
	end.

%% @private
-spec(do_recipe/2 :: (Recipe :: recipe(), State :: #state{}) -> recipe()).
do_recipe([{Ticks, Op, Args, Runs} | Recipe], #state{ticked=Ticked} = State) when Ticks rem Ticked == 0 -> 
	Doneop = do_operation({Ticks, Op, Args, Runs}, State),
	case Doneop of 
		% TODO {T, O, A, R}?
		{T, O, A, R} when Runs =:= run_once -> 
			%add to the output recipe
			
			[{T, O, A, R} | do_recipe(Recipe, State)];
		{T, O, A, R} when Runs =:= run_many -> 
			lists:append([{T, O, A, R}, {Ticks, Op, Args, Runs}], do_recipe(Recipe, State));
		ok when Runs =:= run_many -> 
			[{Ticks, Op, Args, Runs} | do_recipe(Recipe, State)];
		ok when Runs =:= run_once ->
			do_recipe(Recipe, State)
			% don't, just dance.
	end;
do_recipe([Head | Recipe], State) -> 
	% this is here in case a recipe is not due to be run.
	[Head | do_recipe(Recipe, State)];
do_recipe([], _State) -> 
	[].

%% @private
-spec(do_operation/2 :: (Recipe :: recipe_step(), State :: #state{}) -> 'ok' | recipe_step()).
do_operation({_Ticks, Op, Args, _Runs}, State) -> 
	?CONSOLE("do_opertion", []),
	#state{queue=Queuename, call=Callid} = State,
	Pid = queue_manager:get_queue(Queuename),
	case Op of
		add_skills -> 
			call_queue:add_skills(Pid, Callid, Args),
			ok;
		remove_skills -> 
			call_queue:remove_skills(Pid, Callid, Args),
			ok;
		set_priority -> 
			[Priority] = Args,
			call_queue:set_priority(Pid, Callid, Priority),
			ok;
		voicemail -> 
			?CONSOLE("NIY",[]),
			ok;
		add_recipe -> 
			list_to_tuple(Args);
		announce -> 
			?CONSOLE("NIY",[]),
			ok
	end.

-ifdef(EUNIT).


queue_interaction_test_() -> 
	["testpx", _Host] = string:tokens(atom_to_list(node()), "@"),
	mnesia:stop(),
	mnesia:delete_schema([node()]),
	mnesia:create_schema([node()]),
	mnesia:start(),
	{timeout, 60, 
	{
		foreach,
		fun() -> 
			queue_manager:start([node()]),
			{ok, Pid} = queue_manager:add_queue(testqueue),
			{ok, Dummy} = dummy_media:start(#call{id="testcall", skills=[english, testskill]}),
			call_queue:add(Pid, 1, Dummy),
			register(media_dummy, Dummy),
			{Pid, Dummy}
		end,
		fun({Pid, Dummy}) -> 
			unregister(media_dummy),
			try call_queue:stop(Pid)
			catch
				exit:{noproc, Detail} ->
					?debugFmt("caught exit:~p ; some tests will kill the original call_queue process.", [Detail])
			end,
			queue_manager:stop()
		end,
		[
			{"Add skills once",
			fun() -> 
				{exists, Pid} = queue_manager:add_queue(testqueue),
				call_queue:set_recipe(Pid, [{1, add_skills, [newskill1, newskill2], run_once}]),
				{ok, MyPid} = start(whereis(media_dummy), [{1, add_skills, [newskill1, newskill2], run_once}], testqueue),
				receive
				after ?TICK_LENGTH + 2000 ->
					true
				end,
				{_Key, #queued_call{skills=CallSkills}} = call_queue:ask(Pid),
				?assertEqual(lists:sort([english, testskill, newskill1, newskill2]), lists:sort(CallSkills)),
				stop(MyPid)
			end},
			{"remove skills once",
			fun() -> 
				{exists, Pid} = queue_manager:add_queue(testqueue),
				call_queue:set_recipe(Pid, [{1, remove_skills, [testskill], run_once}]),
				{ok, MyPid} = start(whereis(media_dummy), [{1, remove_skills, [testskill], run_once}], testqueue),
				receive
				after ?TICK_LENGTH + 2000 -> 
					true
				end,
				{_Key, #queued_call{skills=CallSkills}} = call_queue:ask(Pid),
				?assertEqual([english], CallSkills),
				stop(MyPid)
			end},
			{"Set Priority once",
			fun() -> 
				{exists, Pid} = queue_manager:add_queue(testqueue),
				call_queue:set_recipe(Pid, [{1, set_priority, [5], run_once}]),
				{ok, MyPid} = start(whereis(media_dummy), [{1, set_priority, [5], run_once}], testqueue),
				receive
				after ?TICK_LENGTH + 2000 -> 
					true
				end,
				{{Prior, _Time}, _Call} = call_queue:ask(Pid),
				?assertEqual(5, Prior),
				stop(MyPid)
			end},
			{"Waiting for queue rebirth",
			fun() -> 
				call_queue_config:new_queue(testqueue, {recipe, [{1, add_skills, [newskill1, newskill2], run_once}]}),
				{exists, Pid} = queue_manager:add_queue(testqueue),
				{_Pri, CallRec} = call_queue:ask(Pid),
				?assertEqual(1, call_queue:call_count(Pid)),
				gen_server:call(Pid, {stop, testy}),
				?assert(is_process_alive(Pid) =:= false),
				receive
				after 1000 -> 
					ok
				end,
				NewPid = queue_manager:get_queue(testqueue),
				?assertEqual(1, call_queue:call_count(NewPid)),
				call_queue:stop(NewPid),
				call_queue_config:destroy(testqueue)
			end
			},
			{"Queue Manager dies",
			fun() -> 
				call_queue_config:new_queue(testqueue, {recipe, [{1, add_skills, [newskill1, newskill2], run_once}]}),
				{exists, Pid} = queue_manager:add_queue(testqueue),
				{_Pri, CallRec} = call_queue:ask(Pid),
				?assertEqual(1, call_queue:call_count(Pid)),
				?CONSOLE("before death:  ~p", [call_queue:print(Pid)]),
				QMPid = whereis(queue_manager),
				exit(QMPid, kill),
				receive
				after 300 -> 
					ok
				end,

				?assert(is_process_alive(QMPid) =:= false),
				?assert(is_process_alive(Pid) =:= false),
				queue_manager:start([node()]),
				receive
				after 1000 -> 
					ok
				end,
				NewPid = queue_manager:get_queue(testqueue),
				
				?assertEqual(1, call_queue:call_count(NewPid)),
				call_queue:stop(NewPid),
				call_queue_config:destroy(testqueue)
			end
			}
		]
	}
	}.

-define(MYSERVERFUNC, fun() -> {ok, Dummy} = dummy_media:start(#call{}), {ok, Pid} = start(Dummy,[{1, set_priority, [5], run_once}], testqueue), {Pid, fun() -> stop(Pid) end} end).

-include("gen_server_test.hrl").


-endif.

