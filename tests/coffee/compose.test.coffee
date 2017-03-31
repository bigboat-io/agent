assert  = require 'assert'
compose = require '../../src/coffee/compose.coffee'

describe 'Compose', ->
  describe 'augmentCompose', ->
    it 'should set the compose version to 2.1', ->
      doc = version: '1.0'
      compose({}).augmentCompose '', {}, doc
      assert.equal doc.version, '2.1'
    it 'should delete the volumes section from the compose file', ->
      doc = volumes: {}
      assert.equal doc.volumes?, true
      compose({}).augmentCompose '', {}, doc
      assert.equal doc.volumes?, false
    it 'should delete the networks section from the compose file', ->
      doc = networks: {}
      assert.equal doc.networks?, true
      compose({}).augmentCompose '', {}, doc
      assert.equal doc.networks?, false

  describe '_restrictCompose', ->
    it 'should drop certain service capabilities', ->
      service =
        cap_add: 1
        cap_drop: 1
        cgroup_parent: 1
        devices: 1
        dns: 1
        dns_search: 1
        networks: 1
        ports: 1
        privileged: 1
        tmpfs: 1
        this_is_not_dropped: 1
      compose({})._restrictCompose '', service
      assert.deepEqual service, this_is_not_dropped: 1

  describe '_migrateLinksToDependsOn', ->
    it 'should leaf the document untouched when there are no links', ->
      doc = services: www: image: 'someimage'
      compose({})._migrateLinksToDependsOn '', doc
      assert.deepEqual doc, services: www: image: 'someimage'
    it 'should merge all links with all depends_on (as list) services', ->
      service =
        links: ['db']
        depends_on: ['some_other_service']
      compose({})._migrateLinksToDependsOn '', service
      assert.deepEqual service, depends_on:
        db: {condition: 'service_started'}
        some_other_service: {condition: 'service_started'}
    it 'should merge all links with all depends_on (as object) services', ->
      service =
        links: ['db']
        depends_on: some_other_service: condition: 'some_condition'
      compose({})._migrateLinksToDependsOn '', service
      assert.deepEqual service, depends_on:
        db: {condition: 'service_started'}
        some_other_service: {condition: 'some_condition'}
    it 'should prefer a dependency from depends_on over one from links if they are the same', ->
      service =
        links: ['db']
        depends_on: db: condition: 'my_specific_condition'
      compose({})._migrateLinksToDependsOn '', service
      assert.deepEqual service, depends_on:
        db: {condition: 'my_specific_condition'}

  describe '_resolvePath', ->
    it 'should resolve a path relative to a given root', ->
      c = compose({})
      assert.equal c._resolvePath('/some/root', '/my/rel/path'), '/some/root/my/rel/path'
      assert.equal c._resolvePath('/some/root/', '/my/rel/path'), '/some/root/my/rel/path'
      assert.equal c._resolvePath('/some/root', 'my/rel/path'), '/some/root/my/rel/path'
      assert.equal c._resolvePath('/some/root', './my/rel/path'), '/some/root/my/rel/path'
      assert.equal c._resolvePath('/some/root', '/other/../my/rel/path'), '/some/root/my/rel/path'
      assert.equal c._resolvePath('/some/root/', '/some/root/../../one/level/up'), '/some/root/one/level/up'
    it 'should throw an error when a relative path resolves outside of the given root', ->
      assert.throws ->
        compose({})._resolvePath '/some/root/', '../one/level/up'
      , Error
      assert.throws ->
        compose({})._resolvePath '/some/root/', '/../../.././one/level/up'
      , Error

  describe '_addDockerMapping', ->
    it 'should add a volume mapping to the docker socket only when the value of bigboat.container.map_docker label is true', ->
      service =
        volumes: ['existing_volume']
        labels: 'bigboat.container.map_docker': 'true'
      compose({})._addDockerMapping '', service
      assert.deepEqual service, Object.assign {volumes: ['existing_volume', '/var/run/docker.sock:/var/run/docker.sock']}, service
    it 'should not do anything when the label is missing', ->
      service = volumes: ['existing_volume']
      compose({})._addDockerMapping '', service
      assert.deepEqual service, Object.assign {volumes: ['existing_volume']}, service

  describe '_addExtraLabels', ->
    it 'should add bigboat domain and tld labels based on configuration', ->
      service = labels: existing_label: 'value'
      compose({domain:'google', tld:'com'})._addExtraLabels '', service
      assert.deepEqual service, labels:
        existing_label: 'value'
        'bigboat.domain': 'google'
        'bigboat.tld': 'com'

  describe '_addVolumeMapping', ->
    volumeTest = (inputVolume, expectedVolume, opts = {storageBucket: 'bucket1'}) ->
      c = compose dataDir: '/local/data/', domain: 'google'
      service = volumes: [inputVolume]
      c._addVolumeMapping '', service, opts
      assert.deepEqual service, volumes: [expectedVolume]
    it 'should root a volume to a base path (data bucket)', ->
      volumeTest '/my/mapping:/internal/volume', '/local/data/google/bucket1/my/mapping:/internal/volume'
    it 'should remove a volume\'s mapping when no storage bucket is given (no persistence)', ->
      volumeTest '/my/mapping:/internal/volume', '/internal/volume', {}
    it 'should leave a :rw postfix intact', ->
      volumeTest '/my/mapping:/internal/volume:rw', '/local/data/google/bucket1/my/mapping:/internal/volume:rw'
    it 'should leave a :ro postfix intact', ->
      volumeTest '/my/mapping:/internal/volume:ro', '/local/data/google/bucket1/my/mapping:/internal/volume:ro'
    it 'should leave a postfix intact when no storage bucket is given', ->
      volumeTest '/my/mapping:/internal/volume:rw', '/internal/volume:rw', {}
    it 'should not do anything to an unmapped volume', ->
      volumeTest '/internal/volume', '/internal/volume'
    it 'should not do anything to an unmapped volume when no data bucket is given', ->
      volumeTest '/internal/volume', '/internal/volume', {}
    it 'should not do anything to an unmapped volume with :ro when no data bucket is given', ->
      volumeTest '/internal/volume:ro', '/internal/volume:ro', {}
    it 'should not do anything to an unmapped volume with :rw', ->
      volumeTest '/internal/volume:rw', '/internal/volume:rw'
    it 'should discard a volume with a mapping that resolves outside of the bucket root', ->
      c = compose dataDir: '/local/data/', domain: 'google'
      service = volumes: ['../../my-malicious-volume/:/internal']
      c._addVolumeMapping '', service, storageBucket: 'bucket1'
      assert.deepEqual service, volumes: []

  describe '_addNetworkContainer', ->
    invokeTestSubject = (service, cfgNetContainer) ->
      doc = services: {}
      config = domain: 'google', tld: 'com', host_if: 'eth12', vlan: 1234, net_container: cfgNetContainer
      compose(config)._addNetworkContainer 'service1', service, 'instance2', doc
      doc
    containerTest = (serviceType) ->
      service =
        labels:
          'bigboat.service.type': serviceType
      doc = invokeTestSubject service
      assert.equal service.network_mode, 'service:bb-net-service1'
      assert.deepEqual service.depends_on, 'bb-net-service1': condition: 'service_started'
      assert.deepEqual doc.services['bb-net-service1'],
        image: 'ictu/pipes:1'
        environment: eth0_pipework_cmd: "eth12 -i eth0 @CONTAINER_NAME@ dhclient @1234"
        hostname: 'service1.instance2.google.com'
        dns_search: 'instance2.google.com'
        network_mode: 'none'
        cap_add: ['NET_ADMIN']
        labels: 'bigboat.service.type': 'net'
        stop_signal: 'SIGKILL'
    it 'should should add a network container for compose service of type \'service\'', ->
      containerTest 'service'
    it 'should should add a network container for compose service of type \'oneoff\'', ->
      containerTest 'oneoff'
    it 'should inherit all labels from the service container, except the bigboat.service.type label', ->
      service =
        labels:
          'bigboat.service.type': 'service'
          some_other_label: 'value'
      doc  = invokeTestSubject service
      assert.deepEqual doc.services['bb-net-service1'].labels,
        'bigboat.service.type': 'net'
        some_other_label: 'value'

    it 'should set the netcontainer healthcheck when configured', ->
      service =
        labels:
          'bigboat.service.type': 'service'
      doc = invokeTestSubject service, healthcheck: 'some-check'
      assert.equal doc.services['bb-net-service1'].healthcheck, 'some-check'
      assert.deepEqual service.depends_on, 'bb-net-service1': condition: 'service_healthy'

    it 'should use the container_name from the service, if any, to populate the netcontainer name', ->
      service =
        labels:
          'bigboat.service.type': 'oneoff'
        container_name: 'some-name'
      doc = invokeTestSubject service
      assert.equal doc.services['bb-net-service1'].container_name, 'some-name-net'

    it 'should simply change the network_mode to use an existing netcontainer when the service type is anything other than service or oneoff', ->
      service =
        labels:
          'bigboat.service.type': 'something-else'
          'bigboat.service.name': 'myservice'
      doc = invokeTestSubject service
      assert.equal service.network_mode, 'service:bb-net-myservice'
      assert.deepEqual doc, services: {}