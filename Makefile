REBAR ?= rebar
ifneq ($(wildcard rebar),)
	REBAR := ./rebar
endif

.PHONY: clean test docs benchmark docsclean go quick dialyzer

all: get-deps compile

get-deps:
	$(REBAR) get-deps

compile:
	$(REBAR) compile
	$(REBAR) xref skip_deps=true

quick:
	$(REBAR) compile xref skip_deps=true

clean:
	$(REBAR) clean

test:
	$(REBAR) skip_deps=true eunit
test/%:
	$(REBAR) skip_deps=true eunit suites=$*

docs: docsclean
	ln -s . doc/doc
	$(REBAR) skip_deps=true doc

docsclean:
	rm -f doc/*.html doc/*.css doc/erlang.png doc/edoc-info doc/doc

go:
	ERL_LIBS=.:deps erl -name spapi_router -s spr_app ${EXTRA_ARGS}

dialyzer:
	dialyzer -c ebin/ -Wunmatched_returns -Werror_handling -Wrace_conditions
