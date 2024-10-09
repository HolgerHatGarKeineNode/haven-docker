**Haven - Docker Hub Description**

HAVEN (High Availability Vault for Events on Nostr) is the most sovereign personal relay for the Nostr protocol, for
storing and backing up sensitive notes like eCash, private chats, and drafts. It is a relay that is not so dumb, with
features like web of trust, inbox relay, cloud backups, blastr, and the ability to import old notes.

See the [Haven repository](https://github.com/bitvora/haven) for more information.

### The Dockerfile is available here: [Dockerfile](https://github.com/HolgerHatGarKeineNode/haven-docker/blob/master/Dockerfile)

### Requirements

- the scripts are compatible with Linux
- **Docker**: Ensure you have Docker installed on your system. You can download it
  from [here](https://docs.docker.com/get-docker/).
- **Docker Compose**: Ensure you have Docker Compose installed on your system. You can download it
  from [here](https://docs.docker.com/compose/install/).
    - we need the Docker Compose Plugin, so `docker compose` should be available in your terminal

### 0. Clone the Repository

Start by cloning the repository to access the necessary files:

```bash
git clone https://github.com/HolgerHatGarKeineNode/haven-docker
cd haven-docker
```

If you want a specific version, checkout the tag for that version.
You can find the available tags here: [Tags](https://github.com/HolgerHatGarKeineNode/haven-docker/releases)

```bash
git checkout tags/<tag_name>
```

The master branch is the latest version.

### 1. Copy `.env.example` to `.env` and also the template files

You'll need to create an `.env` file based on the example provided in the repository.

```bash
cp .env.example .env
```

You'll also need to copy the template files to the `templates` directory:

```bash
cp -r templates-example/* templates/
```

### 2. Set your environment variables

Open the `.env` file and set the necessary environment variables.

### 3. Create the relays JSON files

Copy the example relay JSON files for your seed and blastr relays:

```bash
cp relays_import.example.json relays_import.json
cp relays_blastr.example.json relays_blastr.json
```

The JSON should contain an array of relay URLs, which default to `wss://` if you don't explicitly specify the protocol.

### 4. Set up Volumes

Ensure the necessary directories for volumes exist and have the correct permissions. These directories are used to
persist data and templates, which are important for the relay's operation:

- `./db` is mapped to `/app/db` inside the container.
- `./templates` is mapped to `/app/templates` inside the container.

You may need to create these directories:

```bash
mkdir -p ./db ./templates
```

### 5. Start with Docker Compose

To start the services using Docker Compose, run the following command:

```bash
./scripts/start-relay.sh
```

This script will start all the services defined in your `docker-compose.yml`.

### 6. Start with Docker Compose on Tor

To start the services with Tor enabled, use the following command:

```bash
./scripts/start-relay-tor.sh
```

This script will start the services as per the configuration in your `docker-compose.tor.yml`, including the Tor
service.

### 7. Stop the Services

To stop the services, run the following command:

```bash
./scripts/stop.sh
```

### 8. Access logs

To access the logs of the services, run the following command:

```bash
./scripts/logs.sh
```

Hier ist die aktualisierte README-Sektion, die den Abruf neuer Release-Tags berücksichtigt:

### 9. Update the Relay

To update the relay, first fetch the latest tags to ensure you have access to any new releases:

```bash
git fetch --tags
```

Then, to switch to a specific version, checkout the tag for that version:

```bash
git checkout tags/<tag_name>
```

If you want to use the latest version on the master branch, execute:

```bash
git checkout master
```

Then, restart the relay:

```bash
./scripts/start-relay.sh
# or
./scripts/start-relay-tor.sh
```

### 10. Updating environment variables or relay JSON files

If you need to update the environment variables or relay JSON files, you can do so by editing the `.env` file or the
`relays_import.json` and `relays_blastr.json` files. After making the changes, restart the relay:

```bash
./scripts/start-relay.sh
# or
./scripts/start-relay-tor.sh
``` 
