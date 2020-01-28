#!/usr/bin/env bash
# Define where to store the generated certs and metadata.
INSTALL_PATH="/opt/ocariot-swarm"

DIR="/tmp/ocariot-config"

# Optional: Ensure the target directory exists and is empty.
rm -rf "${DIR}"
mkdir -p "${DIR}"

# Create the openssl configuration file. This is used for both generating
# the certificate as well as for specifying the extensions. It aims in favor
# of automation, so the DN is encoding and not prompted.
cat > "${DIR}/template_openssl.cnf" << EOF
[req]
default_bits = 2048
encrypt_key  = no # Change to encrypt the private key using des3 or similar
default_md   = sha256
prompt       = no
utf8         = yes

# Speify the DN here so we aren't prompted (along with prompt = no above).
distinguished_name = req_distinguished_name

# Extensions for SAN IP and SAN DNS
req_extensions = v3_req

# Be sure to update the subject to match your organization.
[req_distinguished_name]
C  = UE
ST = Bruxelas
L  = OCARIoT
O  = OCARIoT
CN = ocariot.com

# Allow client and server auth. You may want to only allow server auth.
# Link to SAN names.
[v3_req]
basicConstraints     = CA:FALSE
subjectKeyIdentifier = hash
keyUsage             = digitalSignature, keyEncipherment
extendedKeyUsage     = clientAuth, serverAuth
subjectAltName       = @alt_names

# Alternative names are specified as IP.# and DNS.# for IP addresses and
# DNS accordingly.
[alt_names]
IP.1  = 127.0.0.1
DNS.1 = localhost
EOF

# Create the certificate authority (CA). This will be a self-signed CA, and this
# command generates both the private key and the certificate. You may want to
# adjust the number of bits (4096 is a bit more secure, but not supported in all
# places at the time of this publication).
#
# To put a password on the key, remove the -nodes option.
#
# Be sure to update the subject to match your organization.
openssl req \
  -new \
  -newkey rsa:2048 \
  -days 3600 \
  -nodes \
  -x509 \
  -subj "/C=UE/ST=UE/L=UE/O=OCARIoT CA/CN=ocariot.com" \
  -keyout "${DIR}/ca.key" \
  -out "${DIR}/ca.crt"
# For each server/service you want to secure with your CA, repeat the
# following steps:

generate_certificates()
{
        DNSs=$(echo $1 |  sed "s/,/ /g")
        cat ${DIR}/template_openssl.cnf > ${DIR}/openssl.cnf

        NUMBER=2
        for DNS in ${DNSs}; do
            echo "DNS.${NUMBER} = ${DNS}" >> ${DIR}/openssl.cnf

            if [[ ${NUMBER} -gt 2 ]]; then
                CERTIFICATE=$(echo ${CERTIFICATE} | sed "s/\(${DNS}\|,\)//g")
            fi
            NUMBER=$((NUMBER+1))
        done


        # Generate the private key for the service. Again, you may want to increase
        # the bits to 4096.
        openssl genrsa -out "$2/$3.key" 2048

        # Generate a CSR using the configuration and the key just generated. We will
        # give this CSR to our CA to sign.
        openssl req \
          -new -key "$2/$3.key" \
          -out "$2/$3.csr" \
          -config "${DIR}/openssl.cnf"

        # Sign the CSR with our CA. This will generate a new certificate that is signed
        # by our CA.
        openssl x509 \
          -req \
          -days 120 \
          -in "$2/$3.csr" \
          -CA "${DIR}/ca.crt" \
          -CAkey "${DIR}/ca.key" \
          -CAcreateserial \
          -extensions v3_req \
          -extfile "${DIR}/openssl.cnf" \
          -out "$2/$3.crt"

        # (Optional) Verify the certificate.
        openssl x509 -in "$2/$3.crt" -noout -text

        rm -rf "$2/$3.csr"

        cp ${DIR}/ca.crt $2/
}

mkdir -p ${INSTALL_PATH}/config/ocariot//vault/.certs
rm ${INSTALL_PATH}/config/ocariot//vault/.certs/* -f

mkdir -p ${INSTALL_PATH}/config/ocariot//consul/.certs
rm ${INSTALL_PATH}/config/ocariot//consul/.certs/* -f

CONSUL_CLIENT="vault"

CONSUL_SERVER="consul,server.ocariot.consul"

generate_certificates ${CONSUL_CLIENT} ${INSTALL_PATH}/config/ocariot//vault/.certs "consul_client_vault"

generate_certificates ${CONSUL_SERVER} ${INSTALL_PATH}/config/ocariot//consul/.certs "server"

# (Optional) Remove unused files at the moment
rm -rf "${DIR}/ca.key" "${DIR}/ca.srl" ".srl" ${DIR}/*.cnf
mkdir -p "${DIR}"
