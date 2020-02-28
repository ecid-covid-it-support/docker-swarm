#!/bin/bash

# Function to get server certificates from Vault
get_certificates()
{
    RET_CERT=1
    while [[ $RET_CERT -ne 200 ]]; do
        echo "=> Waiting for certificates..."
        # The requests are realized every 2 seconds
        sleep 2
        # Request to get server certificates from Vault
        RET_CERT=$(curl \
            --header "X-Vault-Token: ${VAULT_ACCESS_TOKEN}" \
            --request POST \
            --data-binary "{\"common_name\": \"${HOSTNAME}\"}" \
            --silent \
            --output /tmp/certificates.json -w "%{http_code}\n" \
            ${VAULT_BASE_URL}:${VAULT_PORT}/v1/pki/issue/${HOSTNAME})
    done

    # Processing certificates
    CERTIFICATES=$(cat /tmp/certificates.json)

    # Placing and referencing private key server for /etc/.certs/server.key
    # through of SSL_KEY_PATH environment variable
    PRIVATE_KEY=$(read_json private_key "${CERTIFICATES}")
    echo -e "${PRIVATE_KEY}" > /etc/.certs/server.key

    # Placing and referencing public key server for /etc/.certs/server.cert
    # through of SSL_CERT_PATH environment variable
    CERTIFICATE=$(read_json certificate "${CERTIFICATES}")
    echo -e "${CERTIFICATE}" > /etc/.certs/server.cert

    # Removing temporary file utilized in request
    rm /tmp/certificates.json
}

# Function used to add the Vault CA certificate to the system, with
# this CA certificate Vault becomes trusted.
# Obs: This is necessary to execute requests to the vault.
add_ca_vault()
{
    mkdir -p /usr/share/ca-certificates/extra
    cat /tmp/vault/ca.crt >> /usr/share/ca-certificates/extra/ca_vault.crt
    echo "extra/ca_vault.crt" >> /etc/ca-certificates.conf
    update-ca-certificates
}

# General function to monitor the receiving of access token from Vault
configure_environment()
{
    # Function used to add the Vault CA certificate to the system, with
    # this CA certificate Vault becomes trusted.
    # Obs: This is necessary to execute requests to the vault.
    add_ca_vault &> /dev/null

    # Creating folder where all certificates will be placed
    mkdir -p /etc/.certs

    # Waiting the access token to be generate.
    # Obs: Every access token file are mapped based in its respective hostname
    RET=$(sed 's/=/ /g' /tmp/access-token-${HOSTNAME} |awk '{print $3}')
    while [[ ${RET} == "" ]]; do
        echo "=> Waiting for Token of ${HOSTNAME} service..."
        # Monitoring the token file every 5 seconds
        sleep 5
        RET=$(sed 's/=/ /g' /tmp/access-token-${HOSTNAME} | awk '{print $3}')
    done

    # Establishing access token received as environment variable
    source /tmp/access-token-${HOSTNAME}
    # Clearing access token file
    > /tmp/access-token-${HOSTNAME}
}

# General function to monitor the receiving of access token from Vault
configure_environment

# Function to get server certificates from Vault
get_certificates

# Removing the environment variable access token
unset VAULT_ACCESS_TOKEN

/run.sh