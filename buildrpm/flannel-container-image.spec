{{{$version := printf "%s.%s.%s" .major .minor .patch }}}
%global debug_package %{nil}
%{!?registry: %global registry container-registry.oracle.com/olcne}

%global _name flannel

Name:           %{_name}-container-image
Version:        {{{ $version }}}
Release:        1%{?dist}
Summary:        Flannel container image for Oracle Linux
License:        ASL 2.0
Group:          System/Management
URL:            https://container-registry.oracle.com
Vendor:         Oracle America
Source0:        %{_name}-%{version}.tar.bz2

BuildRequires: yum-utils

%description
Flannel container image for Oracle Linux

%prep
%setup -q -n %{_name}-%{version}

%global rpm_name %{_name}-%{version}-%{release}.%{_build_arch}
%global docker_tag %{registry}/%{_name}:v%{version}

%build
docker info

%define dockerfile "./Dockerfile.oracle.ol8"
%if %{?oraclelinux} == 9
    %define dockerfile "./Dockerfile.oracle.ol9"
%endif

yum clean all && yumdownloader --destdir=$(pwd) %{rpm_name}

%if %{?oraclelinux} == 8
docker build --pull=never --squash --build-arg RPM=%{rpm_name}.rpm --build-arg https_proxy=${https_proxy} -t %{docker_tag} -f %{dockerfile} .
%else if %{?oraclelinux} == 9
docker build --pull=never --squash --network=host --build-arg RPM=%{rpm_name}.rpm --build-arg https_proxy=${https_proxy} -t %{docker_tag} -f %{dockerfile} .
%endif
docker save -o %{_name}.tar %{docker_tag}

%install
install -p -D -m 644 %{_name}.tar %{buildroot}/usr/local/share/olcne/%{_name}.tar

%files
%license LICENSE
/usr/local/share/olcne/%{_name}.tar

%changelog
* {{{.changelog_timestamp}}} - {{{ $version }}}-1
- Release of flannel-container-image-{{{ $version }}}-1
