FROM centos:centos7

USER root

# Install Python3.8
# RUN yum install -y epel-release && \
#     yum update -y && \
#     yum -y install gcc make openssl-devel bzip2-devel libffi-devel xz-devel wget && \
#     yum clean all && \
#     wget https://www.python.org/ftp/python/3.8.12/Python-3.8.12.tgz && \
#     tar xvf Python-3.8.12.tgz && \
#     cd Python-3.8* && \
#     ./configure --enable-optimizations && \
#     make altinstall && \
#     ln -s /usr/local/bin/python3.8 /usr/local/bin/python3

# Install Java8
RUN yum update -y && yum install -y java-1.8.0-openjdk && yum clean all


######### INSTALLATION OF JUPYTER ##########

LABEL maintainer="Jupyter Project <jupyter@googlegroups.com>"
ARG NB_USER="jovyan"
ARG NB_UID="1000"
ARG NB_GID="100"

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

# Install all OS dependencies for notebook server that starts but lacks all
# features (e.g., download as all possible file formats)
ENV DEBIAN_FRONTEND noninteractive
RUN yum update -y && \
    # - apt-get upgrade is run to patch known vulnerabilities in apt-get packages as
    #   the ubuntu base image is rebuilt too seldom sometimes (less than once a month)
    yum upgrade -y && \
    yum install -y \
    # - bzip2 is necessary to extract the micromamba executable.
    bzip2 \
    ca-certificates \
    sudo \
    # - tini is installed as a helpful container entrypoint that reaps zombie
    #   processes and such of the actual executable we want to start, see
    #   https://github.com/krallin/tini#why-tini for details.
    wget && \
    yum clean all

COPY tini /usr/bin/tini
RUN chmod +x /usr/bin/tini

# Configure environment
ENV CONDA_DIR=/opt/conda \
    SHELL=/bin/bash \
    NB_USER="${NB_USER}" \
    NB_UID=${NB_UID} \
    NB_GID=${NB_GID} \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8
ENV PATH="${CONDA_DIR}/bin:${PATH}" \
    HOME="/home/${NB_USER}"

# Copy a script that we will use to correct permissions after running certain commands
COPY fix-permissions /usr/local/bin/fix-permissions
RUN chmod a+rx /usr/local/bin/fix-permissions

# Enable prompt color in the skeleton .bashrc before creating the default NB_USER
# hadolint ignore=SC2016
RUN sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /etc/skel/.bashrc && \
   # Add call to conda init script see https://stackoverflow.com/a/58081608/4413446
   echo 'eval "$(command conda shell.bash hook 2> /dev/null)"' >> /etc/skel/.bashrc

# Create NB_USER with name jovyan user with UID=1000 and in the 'users' group
# and make sure these dirs are writable by the `users` group.
RUN echo "auth requisite pam_deny.so" >> /etc/pam.d/su && \
    sed -i.bak -e 's/^%admin/#%admin/' /etc/sudoers && \
    sed -i.bak -e 's/^%sudo/#%sudo/' /etc/sudoers && \
    useradd -l -m -s /bin/bash -N -u "${NB_UID}" "${NB_USER}" && \
    mkdir -p "${CONDA_DIR}" && \
    chown "${NB_USER}:${NB_GID}" "${CONDA_DIR}" && \
    chmod g+w /etc/passwd && \
    fix-permissions "${HOME}" && \
    fix-permissions "${CONDA_DIR}"

USER ${NB_UID}

# Pin python version here, or set it to "default"
ARG PYTHON_VERSION=3.8

# Setup work directory for backward-compatibility
RUN mkdir "/home/${NB_USER}/work" && \
    fix-permissions "/home/${NB_USER}"

# Download and install Micromamba, and initialize Conda prefix.
#   <https://github.com/mamba-org/mamba#micromamba>
#   Similar projects using Micromamba:
#     - Micromamba-Docker: <https://github.com/mamba-org/micromamba-docker>
#     - repo2docker: <https://github.com/jupyterhub/repo2docker>
# Install Python, Mamba and jupyter_core
# Cleanup temporary files and remove Micromamba
# Correct permissions
# Do all this in a single RUN command to avoid duplicating all of the
# files across image layers when the permissions change
COPY --chown="${NB_UID}:${NB_GID}" initial-condarc "${CONDA_DIR}/.condarc"
COPY micromamba.tar.bz2 /tmp/micromamba.tar.bz2
WORKDIR /tmp
RUN set -x && \
    arch=$(uname -m) && \
    if [ "${arch}" = "x86_64" ]; then \
        # Should be simpler, see <https://github.com/mamba-org/mamba/issues/1437>
        arch="64"; \
    fi && \
    tar -xvjf /tmp/micromamba.tar.bz2 --strip-components=1 bin/micromamba && \
    PYTHON_SPECIFIER="python=${PYTHON_VERSION}" && \
    if [[ "${PYTHON_VERSION}" == "default" ]]; then PYTHON_SPECIFIER="python"; fi && \
    # Install the packages
    ./micromamba install \
        --root-prefix="${CONDA_DIR}" \
        --prefix="${CONDA_DIR}" \
        --yes \
        "${PYTHON_SPECIFIER}" \
        'mamba' \
        'jupyter_core' && \
    rm micromamba && \
    # Pin major.minor version of python
    mamba list python | grep '^python ' | tr -s ' ' | cut -d ' ' -f 1,2 >> "${CONDA_DIR}/conda-meta/pinned" && \
    mamba clean --all -f -y && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "/home/${NB_USER}"

# Configure container startup
ENTRYPOINT ["tini", "-g", "--"]
CMD ["start.sh"]

# Copy local files as late as possible to avoid cache busting
COPY start.sh /usr/local/bin/

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}

WORKDIR "${HOME}"

LABEL maintainer="Jupyter Project <jupyter@googlegroups.com>"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

COPY run-one /usr/bin/run-one
RUN yum update -y && \
    yum install -y \
    liberation-fonts \
    # - pandoc is used to convert notebooks to html files
    #   it's not present in aarch64 ubuntu image, so we install it here
    pandoc \
    # - run-one - a wrapper script that runs no more
    #   than one unique  instance  of  some  command with a unique set of arguments,
    #   we use `run-one-constantly` to support `RESTARTABLE` option
    #run-one && \
    chmod +x /usr/bin/run-one && \
    ln -s /usr/bin/run-one /usr/bin/keep-one-running && \
    ln -s /usr/bin/run-one /usr/bin/run-one-constantly && \
    ln -s /usr/bin/run-one /usr/bin/run-one-until-failure && \
    ln -s /usr/bin/run-one /usr/bin/run-one-until-success && \
    ln -s /usr/bin/run-one /usr/bin/run-this-one && \
    yum clean all


USER ${NB_UID}

# Install Jupyter Notebook, Lab, and Hub
# Generate a notebook server config
# Cleanup temporary files
# Correct permissions
# Do all this in a single RUN command to avoid duplicating all of the
# files across image layers when the permissions change
WORKDIR /tmp
RUN mamba install --quiet --yes \
    'notebook' \
    'jupyterhub' \
    'jupyterlab' && \
    jupyter notebook --generate-config && \
    mamba clean --all -f -y && \
    npm cache clean --force && \
    jupyter lab clean && \
    rm -rf "/home/${NB_USER}/.cache/yarn" && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "/home/${NB_USER}"

EXPOSE 8888

# Configure container startup
CMD ["start-notebook.sh"]

# Copy local files as late as possible to avoid cache busting
COPY start-notebook.sh start-singleuser.sh /usr/local/bin/
# Currently need to have both jupyter_notebook_config and jupyter_server_config to support classic and lab
COPY jupyter_server_config.py /etc/jupyter/

# Fix permissions on /etc/jupyter as root
USER root

# Legacy for Jupyter Notebook Server, see: [#1205](https://github.com/jupyter/docker-stacks/issues/1205)
RUN sed -re "s/c.ServerApp/c.NotebookApp/g" \
    /etc/jupyter/jupyter_server_config.py > /etc/jupyter/jupyter_notebook_config.py && \
    fix-permissions /etc/jupyter/

# HEALTHCHECK documentation: https://docs.docker.com/engine/reference/builder/#healthcheck
# This healtcheck works well for `lab`, `notebook`, `nbclassic`, `server` and `retro` jupyter commands
# https://github.com/jupyter/docker-stacks/issues/915#issuecomment-1068528799
HEALTHCHECK  --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -O- --no-verbose --tries=1 --no-check-certificate \
    http${GEN_CERT:+s}://localhost:8888${JUPYTERHUB_SERVICE_PREFIX:-/}api || exit 1

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}

WORKDIR "${HOME}"

LABEL maintainer="Jupyter Project <jupyter@googlegroups.com>"

# Fix: https://github.com/hadolint/hadolint/wiki/DL4006
# Fix: https://github.com/koalaman/shellcheck/wiki/SC3014
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

# Install all OS dependencies for fully functional notebook server
RUN yum update -y && \
    yum install -y \
    # Common useful utilities
    git \
    nano \
    tzdata \
    unzip \
    vim \
    # git-over-ssh
    openssh-clients \
    # less is needed to run help in R
    # see: https://github.com/jupyter/docker-stacks/issues/1588
    less \
    # nbconvert dependencies
    # https://nbconvert.readthedocs.io/en/latest/install.html#installing-tex
    texlive-xetex \
    texlive-collection-fontsrecommended \
    texlive-collection-latexrecommended \
    # Enable clipboard on Linux host systems
    xclip && \
    yum clean all

# Create alternative for nano -> nano-tiny
#RUN update-alternatives --install /usr/bin/nano nano /bin/nano-tiny 10

# Switch back to jovyan to avoid accidental container runs as root
USER ${NB_UID}

# Add R mimetype option to specify how the plot returns from R to the browser
COPY --chown=${NB_UID}:${NB_GID} Rprofile.site /opt/conda/lib/R/etc/

LABEL maintainer="Jupyter Project <jupyter@googlegroups.com>"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root

# Spark dependencies
# Default values can be overridden at build time
# (ARGS are in lower case to distinguish them from ENV)
ARG spark_version="3.1.3"
ARG hadoop_version="2.7"
ARG scala_version
ARG spark_checksum="769db39a560a95fd88b58ed3e9e7d1e92fb68ee406689fb4d30c033cb5911e05c1942dcc70e5ec4585df84e80aabbc272b9386a208debda89522efff1335c8ff"
ARG openjdk_version="8"

ENV APACHE_SPARK_VERSION="${spark_version}" \
    HADOOP_VERSION="${hadoop_version}"

RUN yum update -y && \
    yum install -y \
    curl && \
    yum clean all

# Spark installation
WORKDIR /tmp

# RUN if [ -z "${scala_version}" ]; then \
#     wget -qO "spark.tgz" "https://archive.apache.org/dist/spark/spark-${APACHE_SPARK_VERSION}/spark-${APACHE_SPARK_VERSION}-bin-without-hadoop.tgz"; \
#   else \
#     wget -qO "spark.tgz" "https://archive.apache.org/dist/spark/spark-${APACHE_SPARK_VERSION}/spark-${APACHE_SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}-scala${scala_version}.tgz"; \
#   fi && \
#   tar xzf "spark.tgz" -C /usr/local --owner root --group root --no-same-owner && \
#   rm "spark.tgz"
COPY ./spark-${APACHE_SPARK_VERSION}-bin-without-hadoop.tgz spark.tgz
RUN tar xzf "spark.tgz" -C /usr/local --owner root --group root --no-same-owner && \
    rm "spark.tgz"

# Configure Spark
ENV SPARK_HOME=/usr/local/spark
ENV SPARK_OPTS="--driver-java-options=-Xms1024M --driver-java-options=-Xmx4096M --driver-java-options=-Dlog4j.logLevel=info" \
    PATH="${PATH}:${SPARK_HOME}/bin"

RUN if [ -z "${scala_version}" ]; then \
    ln -s "spark-${APACHE_SPARK_VERSION}-bin-without-hadoop" "${SPARK_HOME}"; \
  else \
    ln -s "spark-${APACHE_SPARK_VERSION}-bin-hadoop${HADOOP_VERSION}-scala${scala_version}" "${SPARK_HOME}"; \
  fi && \
  # Add a link in the before_notebook hook in order to source automatically PYTHONPATH && \
  mkdir -p /usr/local/bin/before-notebook.d && \
  ln -s "${SPARK_HOME}/sbin/spark-config.sh" /usr/local/bin/before-notebook.d/spark-config.sh

# Configure IPython system-wide
COPY ipython_kernel_config.py "/etc/ipython/"
RUN fix-permissions "/etc/ipython/"

RUN mkdir -p /opt/spark/jars/
COPY jersey-bundle-1.17.1.jar /opt/spark/jars/jersey-bundle-1.17.1.jar

USER ${NB_UID}

# Install pyarrow
RUN mamba install --quiet --yes \
    'pyarrow' 'dash' 'jupyter-dash' 'pandas' && \
    jupyter lab build && \
    mamba clean --all -f -y && \
    fix-permissions "${CONDA_DIR}" && \
    fix-permissions "/home/${NB_USER}"


WORKDIR "${HOME}"
EXPOSE 4040