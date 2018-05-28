all: compile
dev: compile check test

clean:
	rebar3 clean

test:
	rebar3 eunit && rebar3 cover

compile:
	rebar3 compile

check:
	rebar3 dialyzer
