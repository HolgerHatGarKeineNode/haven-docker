**Haven - Docker Hub Description**

HAVEN (High Availability Vault for Events on Nostr) is the most sovereign personal relay for the Nostr protocol, for
storing and backing up sensitive notes like eCash, private chats, and drafts. It is a relay that is not so dumb, with
features like web of trust, inbox relay, cloud backups, blastr, and the ability to import old notes.

### 0. Clone the Repository

Start by cloning the repository to access the necessary files:

```bash
git clone https://github.com/HolgerHatGarKeineNode/haven-docker
cd haven-docker
```

### 1. Copy `.env.example` to `.env`

You'll need to create an `.env` file based on the example provided in the repository.

```bash
cp .env.example .env
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
./scripts/start.sh
```

This script will start all the services defined in your `docker-compose.yml`.

### 6. Start with Docker Compose on Tor

To start the services with Tor enabled, use the following command:

```bash
./scripts/start_tor.sh
```

This script will start the services as per the configuration in your `docker-compose.tor.yml`, including the Tor
service.

### 7. Stop the Services

To stop the services, run the following command:

```bash
./scripts/stop.sh
# or
./scripts/stop_tor.sh
```
