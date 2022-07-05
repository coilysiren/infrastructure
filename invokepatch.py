# builtin
import inspect
import unittest.mock

# 3rd party
import invoke


def fix_annotations():
    """
    Pyinvoke doesnt accept annotations by default, this fix that
    Based on: https://github.com/pyinvoke/invoke/pull/606

    via this comment:
    https://github.com/pyinvoke/invoke/issues/357#issuecomment-583851322
    """

    def patched_inspect_getargspec(func):
        spec = inspect.getfullargspec(func)
        return inspect.ArgSpec(*spec[0:4])

    org_task_argspec = invoke.tasks.Task.argspec

    def patched_task_argspec(*args, **kwargs):
        with unittest.mock.patch(
            target="inspect.getargspec", new=patched_inspect_getargspec
        ):
            return org_task_argspec(*args, **kwargs)

    invoke.tasks.Task.argspec = patched_task_argspec
