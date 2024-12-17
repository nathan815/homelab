TAG=latest

.PHONY: docker-build-push docker-run ansible-deploy-playbook deploy

docker-deployment-build:
	docker buildx build -t ncr.lan/lanindex:${TAG} --platform=linux/amd64 --platform=linux/arm64 --platform=linux/arm/v7 --push --output=type=registry,registry.insecure=true .

docker-build:
	docker build -t lanindex .

docker-run:
	docker run --rm -p 8080:80 -v $(PWD)/config.json:/app/config.json lanindex

ansible-deploy-playbook:
	cd ../ansible && ./ansible_playbook.sh playbooks/core-services.yml --tag lanindex --limit pi01

deploy: docker-deployment-build ansible-deploy-playbook

pip-compile:
	uv pip compile pyproject.toml > requirements.txt

run:
	uv run python main.py
