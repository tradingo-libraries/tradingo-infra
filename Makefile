ANSIBLE = ansible-playbook -u admin
INVENTORY = inventory/hosts.yml

.PHONY: deploy deploy-monitoring sync-platform deploy-crons cluster-status bootstrap setup-docker-mcp deploy-docker-mcp

deploy:
	$(ANSIBLE) playbooks/deploy-stack.yml -e image_tag=$(tag)

deploy-monitoring:
	$(ANSIBLE) playbooks/deploy-monitoring.yml

deploy-docker-mcp:
	$(ANSIBLE) playbooks/deploy-docker-mcp.yml

setup-docker-mcp:
	$(ANSIBLE) playbooks/setup-docker-mcp.yml

sync-platform:
	$(ANSIBLE) playbooks/sync-platform.yml

deploy-crons:
	$(ANSIBLE) playbooks/deploy-crons.yml

cluster-status:
	$(ANSIBLE) playbooks/cluster-status.yml

bootstrap:
	$(ANSIBLE) playbooks/bootstrap-nodes.yml