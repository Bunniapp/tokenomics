#pragma version ^0.4.0
"""
@title LibMulticaller
@author zefram.eth
@license AGPL-3.0
@notice A library for reading the msg.sender from the Multicaller (https://github.com/Vectorized/multicaller).
"""

MULTICALLER_WITH_SENDER: constant(address) = 0x00000000002Fd5Aeb385D324B580FCa7c83823A0
MULTICALLER_WITH_SIGNER: constant(address) = 0x000000000000D9ECebf3C23529de49815Dac1c4c

@view
def sender_or_signer() -> address:
    if msg.sender in [MULTICALLER_WITH_SENDER, MULTICALLER_WITH_SIGNER]:
        response: Bytes[32] = raw_call(msg.sender, b"", max_outsize=32, is_static_call=True)
        # the sender is encoded in the last 20 bytes of the response
        return extract32(response, 0, output_type=address)
    else:
        return msg.sender