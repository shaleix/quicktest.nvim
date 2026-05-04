class TestMath:
    def helper(self):
        return 1

    def test_add(self):
        import time
        time.sleep(1)
        assert 1 + 1 == 2
    def test_add2(self):

        import time
        time.sleep(1)
        assert 1 + 1 == 2


class TestString:
    def test_add(self):
        assert "a" + "b" == "ab"
