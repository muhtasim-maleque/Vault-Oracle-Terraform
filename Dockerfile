# Copyright IBM Corp. 2017, 2026

# Explicitly set the platform
FROM --platform=linux/amd64 ubuntu:22.04


# Install libaio1 dependencies and Vault

RUN apt-get update && apt-get install libaio1
RUN apt-get update && apt-get install -y unzip wget

RUN wget https://releases.hashicorp.com/vault/2.0.4+ent/vault_2.0.4+ent_linux_amd64.zip
RUN unzip vault_2.0.4+ent_linux_amd64.zip && mv vault /usr/local/bin/ && rm vault_2.0.4+ent_linux_amd64.zip

# Default command
CMD ["/bin/bash"]
