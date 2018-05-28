-module(ecoro).

-export([wrap/1]).
-export([start/1]).
-export([resume/1, resume/2]).
-export([yield/0, yield/1]).
-export([shutdown/1]).
-export([is_dead/1]).

%% -----------------------------------------------------------------------------
%%
%% TYPES
%%
%% -----------------------------------------------------------------------------

-record(ecoro, {
  parent  :: pid(),
  process :: pid()
}).

-type ecoro() ::
  #ecoro{}.

-type ecoro_arg() ::
  any().

-type ecoro_func() ::
  fun(() -> ecoro_arg()) |
  fun((ecoro_arg()) -> ecoro_arg()).

-type ecoro_wrap_func() ::
  fun(() -> ecoro_resume_ret()) |
  fun((ecoro_arg()) -> ecoro_resume_ret()).

-type ecoro_resume_ret() ::
  {boolean(), ecoro_arg()} |
  {error, any()}.

-export_type([
  ecoro/0,
  ecoro_arg/0, ecoro_func/0,
  ecoro_wrap_func/0, ecoro_resume_ret/0
]).

-define(ECORO_PROC_DICT_PARENT,  ecoro_proc_dict_parent).
-define(ECORO_PROC_DICT_MONITOR, ecoro_proc_dict_monitor).

%% -----------------------------------------------------------------------------
%%
%% PUBLIC
%%
%% -----------------------------------------------------------------------------

%% -------------------------------------
%% wrap
%% -------------------------------------

-spec wrap(
    ecoro_func()
) -> ecoro_wrap_func().

wrap(Func) ->
  Coro = start(Func),
  case erlang:fun_info(Func, arity) of
    {arity, 0} -> fun() -> resume(Coro) end;
    {arity, 1} -> fun(Arg) -> resume(Coro, Arg) end
  end.

%% -------------------------------------
%% start
%% -------------------------------------

-spec start(
    ecoro_func()
) -> ecoro().

start(Func) ->
  check_coro_func(Func),
  Parent = erlang:self(),
  Process = erlang:spawn(fun() ->
    fill_coro_proc_dict(
      Parent,
      erlang:monitor(process, Parent)),
    Parent ! {erlang:self(), ecoro_started},
    Arg = wait_resume(),
    try
      Ret = case erlang:fun_info(Func, arity) of
        {arity, 0} -> Func();
        {arity, 1} -> Func(Arg)
      end,
      Parent ! {erlang:self(), ecoro_stopped, Ret}
    catch Exception:Reason ->
      Parent ! {erlang:self(), ecoro_abandoned, {Exception, Reason}}
    end
  end),
  receive
    {Process, ecoro_started} ->
      #ecoro{
        parent = Parent,
        process = Process
      }
  end.

%% -------------------------------------
%% resume
%% -------------------------------------

-spec resume(
    ecoro()
) -> ecoro_resume_ret().

resume(Coro) ->
  resume(Coro, undefined).

-spec resume(
    ecoro(), ecoro_arg()
) -> ecoro_resume_ret().

resume(Coro = #ecoro{parent = Parent, process = Process}, Arg) ->
  check_parent_call(Coro),
  Process ! {Parent, ecoro_resume, Arg},
  receive
    {Process, ecoro_yielded,   Ret} -> {true,  Ret};
    {Process, ecoro_stopped,   Ret} -> {false, Ret};
    {Process, ecoro_abandoned, Err} -> {error, Err}
  end.

%% -------------------------------------
%% yield
%% -------------------------------------

-spec yield(
) -> ecoro_arg().

yield() ->
  yield(undefined).

-spec yield(
    ecoro_arg()
) -> ecoro_arg().

yield(Arg) ->
  {Parent, _Monitor} = extract_coro_proc_dict(),
  Parent ! {erlang:self(), ecoro_yielded, Arg},
  wait_resume().

%% -------------------------------------
%% shutdown
%% -------------------------------------

-spec shutdown(
    ecoro()
) -> ok.

shutdown(Coro = #ecoro{parent = Parent, process = Process}) ->
  check_parent_call(Coro),
  Process ! {Parent, ecoro_shutdown},
  receive
    {Process, ecoro_stopped} -> ok
  end.

%% -------------------------------------
%% is_dead
%% -------------------------------------

-spec is_dead(
    ecoro()
) -> boolean().

is_dead(#ecoro{process = Process}) ->
  not erlang:is_process_alive(Process).

%% -----------------------------------------------------------------------------
%%
%% PRIVATE
%%
%% -----------------------------------------------------------------------------

%% -------------------------------------
%% wait_resume
%% -------------------------------------

-spec wait_resume(
) -> ecoro_arg().

wait_resume() ->
  {Parent, Monitor} = extract_coro_proc_dict(),
  receive
    {'DOWN', Monitor, process, Parent, _Reason} ->
      erlang:exit(erlang:self(), normal);
    {Parent, ecoro_resume, Arg} ->
      Arg;
    {Parent, ecoro_shutdown} ->
      Parent ! {erlang:self(), ecoro_stopped},
      erlang:exit(erlang:self(), normal)
  end.

%% -------------------------------------
%% fill_coro_proc_dict
%% -------------------------------------

-spec fill_coro_proc_dict(
    pid(), reference()
) -> ok.

fill_coro_proc_dict(Parent, Monitor) ->
  erlang:put(?ECORO_PROC_DICT_PARENT, Parent),
  erlang:put(?ECORO_PROC_DICT_MONITOR, Monitor).

-spec extract_coro_proc_dict(
) -> {pid(), reference()}.

extract_coro_proc_dict() ->
  Parent = erlang:get(?ECORO_PROC_DICT_PARENT),
  Monitor = erlang:get(?ECORO_PROC_DICT_MONITOR),
  Parent /= undefined orelse erlang:error(ecoro_parent_error),
  Monitor /= undefined orelse erlang:error(ecoro_monitor_error),
  {Parent, Monitor}.

%% -------------------------------------
%% check_coro_func
%% -------------------------------------

-spec check_coro_func(
    ecoro_func()
) -> ok.

check_coro_func(Func) ->
  case erlang:fun_info(Func, arity) of
    {arity, 0} -> ok;
    {arity, 1} -> ok;
    _ -> erlang:error(ecoro_coro_func_arity_error)
  end.

%% -------------------------------------
%% check_parent_call
%% -------------------------------------

-spec check_parent_call(
    ecoro()
) -> ok.

check_parent_call(Coro = #ecoro{parent = Parent}) ->
  is_dead(Coro) == false orelse erlang:error(ecoro_is_dead),
  erlang:self() == Parent orelse erlang:error(ecoro_parent_error),
  ok.

%% -----------------------------------------------------------------------------
%%
%% TESTS
%%
%% -----------------------------------------------------------------------------

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

%% -------------------------------------
%% wrap_test
%% -------------------------------------

wrap_00_test() ->
  WrapFunc = wrap(fun() ->
    1
  end),
  {false, 1} = WrapFunc().

wrap_01_test() ->
  WrapFunc = wrap(fun(1) ->
    2
  end),
  {false, 2} = WrapFunc(1).

wrap_02_test() ->
  try
    undefined = wrap(fun(1, 2) -> 3 end)
  catch error:ecoro_coro_func_arity_error -> ok end.

%% -------------------------------------
%% start_resume_test
%% -------------------------------------

start_resume_00_test() ->
  Coro = start(fun() ->
    1
  end),
  false = is_dead(Coro),
  {false, 1} = resume(Coro),
  true = is_dead(Coro).

start_resume_01_test() ->
  Coro = start(fun(1) ->
    2
  end),
  false = is_dead(Coro),
  {false, 2} = resume(Coro, 1),
  true = is_dead(Coro).

start_resume_02_test() ->
  try
    undefined = start(fun(1, 2) -> 3 end)
  catch error:ecoro_coro_func_arity_error -> ok end.

%% -------------------------------------
%% resume_error_test
%% -------------------------------------

resume_error_00_test() ->
  Coro = start(fun() ->
    erlang:throw(some_reason)
  end),
  {error, {throw, some_reason}} = resume(Coro).

resume_error_01_test() ->
  Coro = start(fun(1) ->
    erlang:error(some_reason)
  end),
  {error, {error, some_reason}} = resume(Coro, 1).

%% -------------------------------------
%% parent_error_test
%% -------------------------------------

parent_error_00_test() ->
  Self = erlang:self(),
  Parent = erlang:spawn(fun() ->
    Func = fun() ->
      1
    end,
    1 = Func(),
    Coro = start(Func),
    Self ! {erlang:self(), child_coro, Coro},
    erlang:exit(Self, normal)
  end),
  receive
    {Parent, child_coro, Coro} ->
      timer:sleep(100),
      true = is_dead(Coro)
  end.

parent_error_01_test() ->
  Self = erlang:self(),
  Parent = erlang:spawn(fun() ->
    Func = fun() ->
      1
    end,
    1 = Func(),
    Coro = start(Func),
    Self ! {erlang:self(), child_coro, Coro}
  end),
  receive
    {Parent, child_coro, Coro} ->
      try
        undefined = resume(Coro)
      catch error:ecoro_parent_error -> ok end
  end.

%% -------------------------------------
%% yield_test
%% -------------------------------------

yield_00_test() ->
  Coro = start(fun() ->
    undefined = yield()
  end),
  {true,  undefined} = resume(Coro),
  {false, undefined} = resume(Coro).

yield_01_test() ->
  Coro = start(fun(1) ->
    3 = yield(2)
  end),
  {true,  2} = resume(Coro, 1),
  {false, 3} = resume(Coro, 3).

%% -------------------------------------
%% shutdown_test
%% -------------------------------------

shutdown_00_test() ->
  Func = fun() ->
    1
  end,
  1 = Func(),
  Coro = start(Func),
  false = is_dead(Coro),
  ok = shutdown(Coro),
  true = is_dead(Coro).

shutdown_01_test() ->
  Func = fun(1) ->
    3 = yield(2)
  end,
  Coro = start(Func),
  {true, 2} = resume(Coro, 1),
  false = is_dead(Coro),
  ok = shutdown(Coro),
  true = is_dead(Coro).

%% ------------------------------------
%% examples
%% ------------------------------------

example0_test() ->
  %% create coroutine
  Coro = ecoro:start(fun(State0) ->
    io:format("~p~n", [State0]),
    State1 = ecoro:yield(State0 + 1),
    io:format("~p~n", [State1]),
    State2 = ecoro:yield(State1 + 1),
    io:format("~p~n", [State2]),
    State2 + 1
  end),
  %% start coroutine (print 0 and return true because coro is alive)
  {true,  State1 = 1} = ecoro:resume(Coro, 0),
  %% resume coroutine (print 1)
  {true,  State2 = 2} = ecoro:resume(Coro, State1),
  %% resume coroutine (print 2 and return false because coro is ended)
  {false, _State3 = 3} = ecoro:resume(Coro, State2).

example1_test() ->
  %% create bad coroutine
  Coro = ecoro:start(fun() ->
    io:format("1~n"),
    ecoro:yield(),
    erlang:throw(some_throw_reason)
  end),
  %% start coroutine (print 1 and return true because coro is alive)
  {true, _} = ecoro:resume(Coro),
  %% resume coroutine (return error with throw reason)
  {error, {throw, some_throw_reason}} = ecoro:resume(Coro).

-endif.
