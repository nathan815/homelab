TAG=latest

.PHONY: docker-build docker-deployment-build docker-run deploy

docker-deployment-build:
	docker buildx build -t ghcr.io/nathan815/lanindex:${TAG} --platform=linux/arm64 --push .

docker-build:
	docker build -t lanindex .

docker-run:
	docker run --rm -p 8080:80 -v $(PWD)/config.json:/app/config.json lanindex

# Manual fallback: CI normally does this (.github/workflows/deploy.yml, then Woodpecker calls Komodo).
# Pushes :latest; the stack runs the sha in Komodo's LANINDEX_IMAGE_TAG variable, so set it to latest before redeploying.
deploy: docker-deployment-build
	@echo "Pushed. Redeploy the lanindex stack in Komodo."

pip-compile:
	uv pip compile pyproject.toml > requirements.txt

run:
	uv run python main.py
