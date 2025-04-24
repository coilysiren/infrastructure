import invoke

from src.backend import backend_collection
from src.core import core_collection
from src.core_keeper import core_keeper_collection
from src.eco import eco_collection
from src.k8s import k8s_collection
from src.llama import llama_collection

namespace = invoke.Collection()
namespace.add_collection(k8s_collection)
namespace.add_collection(backend_collection)
namespace.add_collection(eco_collection)
namespace.add_collection(core_keeper_collection)
namespace.add_collection(core_collection)
namespace.add_collection(llama_collection)
