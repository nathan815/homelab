TAG=latest
# buildx builder configured to allow plain-HTTP pushes to ncr.lan
BUILDER=mybuilder

.PHONY: docker-build docker-deployment-build docker-run deploy

docker-deployment-build:
	docker buildx build --builder ${BUILDER} -t ncr.lan/lanindex:${TAG} --platform=linux/arm64 --push --output=type=registry,registry.insecure=true .

docker-build:
	docker build -t lanindex .

docker-run:
	docker run --rm -p 8080:80 -v $(PWD)/config.json:/app/config.json lanindex

# Manual fallback: CI normally does this (.woodpecker/lanindex.yaml). Push, then redeploy the stack in Komodo.
deploy: docker-deployment-build
	@echo "Pushed. Redeploy the lanindex stack in Komodo."

pip-compile:
	uv pip compile pyproject.toml > requirements.txt

run:
	uv run python main.py
