FROM debian:latest

RUN apt update && \
    apt install -y curl bpfcc-tools perl
      
RUN VERSION="v1.23.0" && \
    curl -L https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-${VERSION}-linux-amd64.tar.gz --output crictl-${VERSION}-linux-amd64.tar.gz && \
    tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin        
RUN curl https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl --output flamegraph.pl && \
    chmod +x flamegraph.pl
RUN curl -LO http://security.ubuntu.com/ubuntu/pool/main/l/linux-azure/linux-azure-headers-5.4.0-1059_5.4.0-1059.62_all.deb && \
    curl -LO http://archive.ubuntu.com/ubuntu/pool/main/l/linux-azure/linux-headers-5.4.0-1059-azure_5.4.0-1059.62_amd64.deb && \
    dpkg -i linux-azure-headers-5.4.0-1059_5.4.0-1059.62_all.deb && \
    dpkg -i linux-headers-5.4.0-1059-azure_5.4.0-1059.62_amd64.deb


ENTRYPOINT [ "/bin/bash"]

#podman build . -f ./azure.5.4.0-1059.dockerfile -t dcasati/ebpf-tools:azure.5.4.0-1059
