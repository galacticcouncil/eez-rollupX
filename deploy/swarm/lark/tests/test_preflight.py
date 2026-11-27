"""Lark's first slice is offline rendering and read-only API discovery."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch
import urllib.error


REPO = Path(__file__).resolve().parents[4]
SPEC = importlib.util.spec_from_file_location('lark', REPO / 'scripts/lark-swarmpit.py')
lark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lark)
NODE = 'a' * 25
ADDRESS = '0x' + '12' * 20


class ApiTest(unittest.TestCase):
    def client(self, directory, token='example-token', mode=0o600, url='https://example.org/#/'):
        path = Path(directory) / 'token'
        path.write_text(token)
        path.chmod(mode)
        return lark.Swarmpit(url, path)

    def test_https_and_private_token_are_required(self):
        with tempfile.TemporaryDirectory() as directory:
            for url in ('http://example.org', 'https://user:password@example.org',
                        'https://example.org/?token=secret', 'https://example.org/unrelated'):
                with self.subTest(url=url), self.assertRaises(lark.PreflightError):
                    self.client(directory, url=url)
            with self.assertRaisesRegex(lark.PreflightError, 'private'):
                self.client(directory, mode=0o644)
            for token in ('', 'Bearer ', 'one\ntwo'):
                with self.subTest(token=token), self.assertRaises(lark.PreflightError):
                    self.client(directory, token=token)

    def test_bearer_is_normalized_and_requests_are_get_only(self):
        with tempfile.TemporaryDirectory() as directory:
            client = self.client(directory, token='Bearer example-token\n')
            response = Mock()
            response.__enter__ = Mock(return_value=io.BytesIO(b'[]'))
            response.__exit__ = Mock(return_value=False)
            client.opener.open = Mock(return_value=response)
            self.assertEqual(client.get('nodes'), [])
            request = client.opener.open.call_args.args[0]
            self.assertEqual(request.full_url, 'https://example.org/api/nodes')
            self.assertEqual(request.get_method(), 'GET')
            self.assertEqual(request.get_header('Authorization'), 'Bearer example-token')
            self.assertEqual(client.opener.open.call_args.kwargs['timeout'], 30)
            with self.assertRaises(lark.PreflightError):
                client.get('secrets/another-task')

    def test_mutation_boundary_rejects_unrelated_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            client = self.client(directory)
            client.request = Mock(return_value=None)
            for resource, body in [('secrets', {'secretName': 'platform-password'}),
                                   ('volumes', {'volumeName': 'other-data'}),
                                   ('stacks/platform', {'name': 'platform'}),
                                   ('stacks', {'name': 'other'}),
                                   ('nodes/' + NODE, {})]:
                with self.subTest(resource=resource), self.assertRaises(lark.PreflightError):
                    client.post(resource, body)
            client.request.assert_not_called()
            client.post('secrets', {'secretName': 'eez-lark-1-engine-jwt', 'data': 'example'})
            client.request.assert_called_once()

    def test_redirects_and_server_error_bodies_cannot_expose_token(self):
        with self.assertRaises(lark.PreflightError):
            lark.NoRedirects().redirect_request(None, None, 302, '', {}, 'https://elsewhere.org')
        with tempfile.TemporaryDirectory() as directory:
            client = self.client(directory)
            client.opener.open = Mock(side_effect=urllib.error.HTTPError(
                'https://example.org/api/nodes', 401, 'example-token', {}, io.BytesIO(b'example-token')))
            with self.assertRaisesRegex(lark.PreflightError, 'HTTP 401') as error:
                client.get('nodes')
            self.assertNotIn('example-token', str(error.exception))

    def test_inventory_discards_environments_secrets_and_nested_stack_services(self):
        source = {'nodes': [{'id': NODE, 'resources': {'cpu': 48, 'memory': 128752},
                            'stats': {'disk': {'free': 100, 'secret': 'private'}, 'other': 'private'}}],
                  'services': [{'serviceName': 'example', 'variables': ['private'],
                                'status': {'message': 'private'},
                                'secrets': ['private'], 'repository': {'password': 'private'}}],
                  'stacks': [{'stackName': 'example', 'services': [{'variables': ['private']}]}],
                  'networks': [{'networkName': 'example', 'labels': ['private']}]}
        api = Mock()
        api.get.side_effect = source.__getitem__
        result = lark.inventory(api)
        self.assertNotIn('private', json.dumps(result))
        self.assertEqual(result['nodes'][0]['stats'], {'disk': {'free': 100}})
        self.assertEqual(result['services'], [{'serviceName': 'example', 'status': {}}])
        self.assertEqual([call.args[0] for call in api.get.call_args_list], list(source))

    def test_unexpected_inventory_cannot_be_reported_as_success(self):
        api = Mock()
        api.get.return_value = {'error': 'private'}
        with self.assertRaisesRegex(lark.PreflightError, 'inventory format'):
            lark.inventory(api)


class L1ProfileTest(unittest.TestCase):
    def test_ids_storage_placement_and_fee_recipient_reach_runtime(self):
        stack = lark.render_l1(NODE, ADDRESS)
        self.assertEqual(set(stack['services']), {'execution', 'beacon', 'validator'})
        for service in stack['services'].values():
            self.assertNotIn('ports', service)
            self.assertIn('@sha256:', service['image'])
            self.assertEqual(service['deploy']['placement']['constraints'], [f'node.id == {NODE}'])
            self.assertEqual(service['deploy']['update_config']['order'], 'stop-first')
            self.assertEqual(service['logging']['options'], {'max-size': '20m', 'max-file': '3'})
            self.assertIn('limits', service['deploy']['resources'])
            self.assertIn('reservations', service['deploy']['resources'])
        self.assertIn('--suggested-fee-recipient=' + ADDRESS, stack['services']['validator']['command'])
        for volume in stack['volumes'].values():
            self.assertTrue(volume['external'])
            self.assertTrue(volume['name'].startswith('eez-lark-1-686868-'))
        text = json.dumps(stack)
        for local in ('414141', '424242', 'eez-devnet', 'fixtures', '${'):
            self.assertNotIn(local, text)
        self.assertEqual(stack['secrets']['engine_jwt']['name'], 'eez-lark-1-engine-jwt')

    def test_missing_bad_and_local_fixture_inputs_fail(self):
        for node, recipient in [('', ADDRESS), ('host name', ADDRESS), (NODE, ''),
                                (NODE, '0x' + '0' * 40),
                                (NODE, '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266')]:
            with self.subTest(node=node, recipient=recipient), self.assertRaises(lark.PreflightError):
                lark.render_l1(node, recipient)

    def test_render_is_offline_and_ignores_conflicting_environment(self):
        with patch.dict('os.environ', {'EEZ_LARK_DATA_NODE': 'bad',
                                     'EEZ_LARK_FEE_RECIPIENT': 'bad'}), \
                patch.object(lark.urllib.request, 'build_opener', side_effect=AssertionError('network')):
            self.assertIn('services', lark.render_l1(NODE, ADDRESS))
