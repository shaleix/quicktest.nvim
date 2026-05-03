def test_fail():
    assert 1 == 2


def test_ok():
    import time
    time.sleep(2)
    assert 1 == 2

