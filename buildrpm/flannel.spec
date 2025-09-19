

%if 0%{?with_debug}
# https://bugzilla.redhat.com/show_bug.cgi?id=995136#c12
%global _dwz_low_mem_die_limit 0
%global _find_debuginfo_dwz_opts %{nil}
%else
%global debug_package   %{nil}
%endif

%global provider        github
%global provider_tld    com
%global project         coreos
%global repo            flannel
%global project_dir     %{provider}.%{provider_tld}/%{project}
%global src_project_dir src/%{project_dir}
%global src_flannel_dir %{src_project_dir}/%{repo}
%global provider_prefix %{project_dir}/%{repo}
%global import_path     %{provider_prefix}

%global _buildhost          build-ol%{?oraclelinux}-%{?_arch}.oracle.com

Name:           flannel
Version:        0.27.3
Release:        1%{?dist}
Summary:        Etcd address management agent for overlay networks
License:        ASL 2.0
Group:          System/Management
URL:            https://%{provider_prefix}
Vendor:         Oracle America
Source0:        %{name}-%{version}.tar.bz2


BuildRequires:      golang
BuildRequires:	    glibc-static
Requires:     net-tools
Requires:     iproute
Requires:     iptables
Requires:     ca-certificates

%description
Flannel is an etcd driven address management agent. Most commonly it is used to
manage the ip addresses of overlay networks between systems running containers
that need to communicate with one another.

%prep
%setup -q -n %{repo}-%{version}
go mod tidy

find . -name "*.go" \
       -print |\
              xargs sed -i 's/github.com\/coreos\/flannel\/Godeps\/_workspace\/src\///g'


%build
mkdir -p %{src_project_dir}
ln -s ../../../ %{src_flannel_dir}

export GOPATH=$(pwd)/Godeps/_workspace

# see OLCNE-3381 - for some reason, FIPS doesn't like binary compiled with static flag
#make dist/flanneld
go build -o dist/flanneld \
          -ldflags '-s -w -X github.com/flannel-io/flannel/version.Version=%{version} -linkmode=external -a -v'

%install
install -D -p -m 755 dist/flanneld %{buildroot}/opt/bin/flanneld
install -D -p -m 755 dist/mk-docker-opts.sh %{buildroot}/opt/bin/mk-docker-opts.sh
install -d -m 0755 %{buildroot}/run/%{name}/


%files
%license LICENSE THIRD_PARTY_LICENSES.txt
%doc CONTRIBUTING.md README.md DCO
/opt/bin/flanneld
/opt/bin/mk-docker-opts.sh
%dir /run/%{name}/


%changelog
* Fri Sep 19 2025 Olcne-Builder Jenkins <olcne-builder_us@oracle.com> - 0.27.3-1
- Release of flannel-0.27.3-1
