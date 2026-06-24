.ONESHELL:

PG_IMG ?= postgres:16
PG_PORT ?= 5434
PG_DB  ?= ducto_test
PG_USER?= ducto
PG_PASS?= ducto
PG_NAME?= ducto-pg-js
DATABASE_URL = postgres://$(PG_USER):$(PG_PASS)@localhost:$(PG_PORT)/$(PG_DB)

.PHONY: test test-python test-js test-js-mock test-js-integration clean-db

test: test-python test-js           ## All tests (Python + JS mock + JS integration)

test-python:                        ## Python tests (mock + postgres via pg_tmp)
	cd python && pytest

test-js: test-js-mock test-js-integration  ## All JS tests

test-js-mock:                       ## JS mock tests (no infra needed)
	cd javascript && npx vitest run

test-js-integration:                ## JS postgres integration tests (docker)
	docker rm -f $(PG_NAME) 2>/dev/null; true
	docker run -d --name $(PG_NAME) \
		-e POSTGRES_DB=$(PG_DB) \
		-e POSTGRES_USER=$(PG_USER) \
		-e POSTGRES_PASSWORD=$(PG_PASS) \
		-p $(PG_PORT):5432 \
		$(PG_IMG)
	until docker exec $(PG_NAME) pg_isready -U $(PG_USER) 2>/dev/null; do sleep 1; done
	cd javascript && DATABASE_URL="$(DATABASE_URL)" npx vitest run tests/store-integration.test.ts; \
		rc=$$?; \
		docker stop $(PG_NAME) >/dev/null && docker rm $(PG_NAME) >/dev/null; \
		exit $$rc

clean-db:                           ## Cleanup leftover test pg container
	docker rm -f $(PG_NAME) 2>/dev/null; true
