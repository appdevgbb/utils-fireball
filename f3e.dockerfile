FROM debian:latest

RUN apt update && \
    apt install -y curl bpfcc-tools perl
      
RUN curl https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl --output flamegraph.pl && \
    chmod +x flamegraph.pl

ENTRYPOINT [ "/bin/bash"]

#podman build . -f ./azure.5.4.0-1059.dockerfile -t dcasati/ebpf-tools:azure.5.4.0-1059