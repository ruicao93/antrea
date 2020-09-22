OVS_VERSION=2.14.0

docker build . -f Dockerfile.ubi8.rootfs -t ubi8-openvswitch-tmp:$OVS_VERSION
tmp_container_id=$(docker create ubi8-openvswitch-tmp:$OVS_VERSION)

docker export $tmp_container_id -o ubi8-openvswitch-rootfs.tar.gz
docker build . -f Dockerfile.ubi8 -t ubi8-openvswitch:$OVS_VERSION
rm ubi8-openvswitch-rootfs.tar.gz
docker rm $tmp_container_id