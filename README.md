# ecoro.erl

> Pseudo-coroutines library like [Lua-coroutines](http://www.lua.org/pil/9.1.html) for Erlang.

[![Build Status](https://travis-ci.org/BlackMATov/ecoro.erl.svg?branch=master)](https://travis-ci.org/BlackMATov/ecoro.erl)

# Examples

## Simple ##

~~~erlang

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

~~~

## Error handling ##

~~~erlang

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

~~~
