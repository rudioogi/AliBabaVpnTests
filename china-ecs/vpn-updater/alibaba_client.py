"""Thin wrapper over the Alibaba VPC SDK for the IP-recovery flow.

Two operations needed:
  1. create_customer_gateway(name, ip_address)            → cgw_id
  2. modify_tunnel_attribute(tunnel_id, cgw_id, remote_id) → noop on success

We deliberately do NOT delete the old customer gateway — operator does that
manually when they want a clean rollback option.
"""

from __future__ import annotations

import os

from alibabacloud_tea_openapi import models as open_api_models
from alibabacloud_vpc20160428 import models as vpc_models
from alibabacloud_vpc20160428.client import Client as VpcClient


def _client() -> VpcClient:
    region = os.environ["ALIYUN_REGION"]
    config = open_api_models.Config(
        access_key_id=os.environ["ALIYUN_ACCESS_KEY_ID"],
        access_key_secret=os.environ["ALIYUN_ACCESS_KEY_SECRET"],
        endpoint=f"vpc.{region}.aliyuncs.com",
    )
    return VpcClient(config)


def _find_customer_gateway_by_ip(ip_address: str) -> str | None:
    req = vpc_models.DescribeCustomerGatewaysRequest(
        region_id=os.environ["ALIYUN_REGION"],
    )
    resp = _client().describe_customer_gateways(req)
    for cgw in (resp.body.customer_gateways.customer_gateway or []):
        if cgw.ip_address == ip_address:
            return cgw.customer_gateway_id
    return None


def create_customer_gateway(name: str, ip_address: str) -> str:
    req = vpc_models.CreateCustomerGatewayRequest(
        region_id=os.environ["ALIYUN_REGION"],
        name=name,
        ip_address=ip_address,
        description=f"Auto-created by oogi-vpn-updater for {ip_address}",
    )
    try:
        resp = _client().create_customer_gateway(req)
        return resp.body.customer_gateway_id
    except Exception as e:
        if "InvalidIpAddress.AlreadyExist" in str(e):
            existing_id = _find_customer_gateway_by_ip(ip_address)
            if existing_id:
                return existing_id
        raise


def modify_tunnel_attribute(tunnel_id: str, customer_gateway_id: str, remote_id: str) -> None:
    vpn_connection_id = os.environ["VPN_CONNECTION_ID"]
    ike_config = vpc_models.ModifyTunnelAttributeRequestTunnelOptionsSpecificationTunnelIkeConfig(
        remote_id=remote_id,
    )
    options = vpc_models.ModifyTunnelAttributeRequestTunnelOptionsSpecification(
        customer_gateway_id=customer_gateway_id,
        tunnel_ike_config=ike_config,
    )
    req = vpc_models.ModifyTunnelAttributeRequest(
        region_id=os.environ["ALIYUN_REGION"],
        vpn_connection_id=vpn_connection_id,
        tunnel_id=tunnel_id,
        tunnel_options_specification=options,
    )
    _client().modify_tunnel_attribute(req)
