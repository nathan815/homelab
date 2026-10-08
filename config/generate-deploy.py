#!/usr/bin/env python3
"""
Convert docker-compose files to Kamal deploy.yml format.

Reads:
  - stacks/*/docker-compose.yml
  - config/services-map.yml

Generates:
  - config/deploy.yml
"""

import os
import sys
import yaml
from pathlib import Path
from collections import defaultdict

def load_yaml(filepath):
    """Load YAML file safely."""
    try:
        with open(filepath) as f:
            return yaml.safe_load(f)
    except Exception as e:
        print(f"Error loading {filepath}: {e}")
        return None

def get_service_name(stack_dir):
    """Extract service name from stack directory."""
    return Path(stack_dir).name

def convert_compose_to_kamal(service_name, compose_data):
    """Convert docker-compose service to Kamal role format."""
    if not compose_data or 'services' not in compose_data:
        return None

    # Get the first (main) service in the compose file
    services = compose_data['services']
    if not services:
        return None

    main_service = list(services.values())[0]

    role = {
        'docker': {}
    }

    # Image
    if 'image' in main_service:
        role['docker']['image'] = main_service['image']

    # Ports
    if 'ports' in main_service:
        role['docker']['ports'] = main_service['ports']

    # Volumes
    if 'volumes' in main_service:
        role['docker']['volumes'] = main_service['volumes']

    # Environment variables
    if 'environment' in main_service:
        env_dict = main_service['environment']
        if isinstance(env_dict, list):
            # Convert list format to dict
            env_dict = {item.split('=')[0]: item.split('=', 1)[1] if '=' in item else ''
                       for item in env_dict}
        role['docker']['env'] = env_dict

    # Healthcheck
    if 'healthcheck' in main_service:
        hc = main_service['healthcheck']
        kamal_hc = {}

        if 'test' in hc:
            test = hc['test']
            if isinstance(test, list):
                kamal_hc['test'] = ' '.join(test[1:]) if len(test) > 1 else ' '.join(test)
            else:
                kamal_hc['test'] = test

        if 'interval' in hc:
            kamal_hc['interval'] = hc['interval']
        if 'timeout' in hc:
            kamal_hc['timeout'] = hc['timeout']
        if 'retries' in hc:
            kamal_hc['retries'] = hc['retries']

        if kamal_hc:
            role['docker']['healthcheck'] = kamal_hc

    # Restart policy
    if 'restart_policy' in main_service or 'restart' in main_service:
        # Kamal handles restart automatically, skip
        pass

    return role

def load_services_map():
    """Load service-to-server mapping."""
    map_file = 'config/services-map.yml'
    if not os.path.exists(map_file):
        print(f"Error: {map_file} not found")
        sys.exit(1)

    return load_yaml(map_file)

def find_stacks():
    """Find all stacks with docker-compose files."""
    stacks = {}
    stacks_dir = Path('stacks')

    if not stacks_dir.exists():
        print("Error: stacks/ directory not found")
        sys.exit(1)

    for stack_path in stacks_dir.iterdir():
        if not stack_path.is_dir():
            continue

        compose_file = stack_path / 'docker-compose.yml'
        if compose_file.exists():
            service_name = get_service_name(stack_path)
            compose_data = load_yaml(compose_file)
            if compose_data:
                stacks[service_name] = {
                    'compose_data': compose_data,
                    'path': stack_path
                }

    return stacks

def generate_deploy_yml(stacks, services_map):
    """Generate Kamal deploy.yml from stacks and mapping."""

    deploy = {
        'service': 'homelab',
        'image': 'local/homelab',
        'servers': {},
        'env': {
            'clear': {
                'TZ': 'America/Detroit',
            },
            'secret': services_map.get('secrets', [])
        },
        'roles': {}
    }

    # Build server list and assign services
    service_to_server = defaultdict(list)

    for server_name, server_config in services_map.get('servers', {}).items():
        host = server_config.get('host')
        user = server_config.get('user', 'root')
        services = server_config.get('services', [])

        deploy['servers'][server_name] = {
            'host': host,
            'user': user,
            'roles': services
        }

        for service in services:
            service_to_server[service].append(server_name)

    # Convert docker-compose to Kamal roles
    for service_name, stack_info in stacks.items():
        if service_name not in service_to_server:
            print(f"⚠️  Warning: {service_name} not in services-map.yml, skipping")
            continue

        compose_data = stack_info['compose_data']
        kamal_role = convert_compose_to_kamal(service_name, compose_data)

        if kamal_role:
            deploy['roles'][service_name] = kamal_role
            print(f"✓ Converted {service_name}")
        else:
            print(f"⚠️  Skipped {service_name} (no valid service)")

    return deploy

def write_deploy_yml(deploy_config):
    """Write deploy.yml to disk."""
    output_file = 'config/deploy.yml'

    with open(output_file, 'w') as f:
        yaml.dump(deploy_config, f,
                 default_flow_style=False,
                 sort_keys=False,
                 allow_unicode=True)

    print(f"\n✓ Generated {output_file}")
    print(f"  Servers: {len(deploy_config['servers'])}")
    print(f"  Roles: {len(deploy_config['roles'])}")

def main():
    print("🔄 Converting docker-compose files to Kamal format...\n")

    # Load configuration
    services_map = load_services_map()

    # Find all stacks
    stacks = find_stacks()
    if not stacks:
        print("Error: No stacks found")
        sys.exit(1)

    print(f"Found {len(stacks)} stacks\n")

    # Generate deploy.yml
    deploy_config = generate_deploy_yml(stacks, services_map)

    # Write output
    write_deploy_yml(deploy_config)

    print("\n✓ Done! Review config/deploy.yml before deploying.")
    print("\nNext steps:")
    print("  1. Check config/deploy.yml")
    print("  2. Verify services-map.yml is correct")
    print("  3. Run: kamal deploy")

if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("\n\nAborted")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        sys.exit(1)
