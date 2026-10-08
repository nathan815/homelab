TAG=latest
# buildx builder configured to allow plain-HTTP pushes to ncr.lan
BUILDER=mybuilder

.PHONY: docker-build-push docker-run ansible-deploy-playbook deploy

docker-deployment-build:
	docker buildx build --builder ${BUILDER} -t ncr.lan/lanindex:${TAG} --platform=linux/arm64 --push --output=type=registry,registry.insecure=true .

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
